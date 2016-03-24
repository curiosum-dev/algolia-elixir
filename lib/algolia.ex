defmodule Algolia do
  @moduledoc """
  Elixir implementation of Algolia search API, using Hackney for http requests
  """

  @settings Application.fetch_env!(:algolia, Algolia)
  @application_id  @settings |> Keyword.fetch!(:application_id)
  @api_key         @settings |> Keyword.fetch!(:api_key)

  defp host(:read, 0),
    do: "#{@application_id}-dsn.algolia.net"
  defp host(:write, 0),
    do: "#{@application_id}.algolia.net"
  defp host(_read_or_write, curr_retry) when curr_retry <= 3,
    do: "#{@application_id}-#{curr_retry}.algolianet.com"

  @doc """
  Search multiple indexes
  """
  def search(queries) do
    body = Poison.encode! queries
    path = "*/queries"

    send_request(:read, :post, path, body)
  end

  @doc """
  Search a single index
  """
  def search(index, query, opts) do
    path = "#{index}?query=#{query}" <> opts_to_query_params(opts)
    send_request(:read, :get, path)
  end
  def search(index, query), do: search(index, query, [])

  defp opts_to_query_params([]), do: ""
  defp opts_to_query_params(opts) do
    opts
    |> Stream.map(fn {key, value} ->
      "&#{key}=#{value}"
    end)
    |> Enum.join
    |> URI.encode
  end

  defp send_request(_, _, _, _, 4),
    do: {:error, "Unable to connect to Algolia"}
  defp send_request(read_or_write, method, path),
    do: send_request(read_or_write, method, path, "", 0)
  defp send_request(read_or_write, method, path, body),
    do: send_request(read_or_write, method, path, body, 0)
  defp send_request(read_or_write, method, path, body, curr_retry) do
    url =
      "https://"
      |> Path.join(host(read_or_write, curr_retry))
      |> Path.join("/1/indexes")
      |> Path.join(path)

    headers = [
      "X-Algolia-API-Key": @api_key,
      "X-Algolia-Application-Id": @application_id
    ]

    :hackney.request(method, url, headers, body, [
      :with_body,
      path_encode_fun: &(&1),
      connect_timeout: 2_000 * (curr_retry + 1),
      recv_timeout: 30_000 * (curr_retry + 1),
    ])
    |> case do
      {:ok, 200, _headers, body} ->
        {:ok, body |> Poison.decode!}
      {:ok, code, _, body} ->
        {:error, code, body}
      _ ->
        send_request(read_or_write, method, path, body, curr_retry + 1)
    end
  end

  @doc """
  Get an object in an index by objectID
  """
  def get_object(index, object_id) do
    path = "#{index}/#{object_id}"

    send_request(:read, :get, path)
    |> inject_index_into_response(index)
  end

  @doc """
  Save a single object, with objectID specified
  """
  def save_object(index, object, object_id) when is_bitstring(object_id) do
    body = object |> Poison.encode!
    path = "#{index}/#{object_id}"

    send_request(:write, :put, path, body)
    |> inject_index_into_response(index)
  end

  @doc """
  Save a single object, without objectID specified, must have objectID as
  a field
  """
  def save_object(index, object, id_attribute: id_attribute) do
    object_id = object[id_attribute] || object[to_string id_attribute]

    if !object_id do
      raise "Object must have an objectID"
    end

    save_object(index, object, object_id)
  end
  def save_object(index, object),
    do: save_object(index, object, id_attribute: :objectID)

  @doc """
  Save multiple objects
  """
  def save_objects(index, objects),
    do: save_objects(index, objects, id_attribute: :objectID)
  def save_objects(index, objects, id_attribute: id_attribute) when is_list(objects) do
    objects
    |> add_object_ids(id_attribute: id_attribute)
    |> build_batch_request("updateObject", with_object_id: true)
    |> send_batch_request(index)
  end

  @doc """
  Partially updates an object, takes option upsert: true or false
  """
  def partial_update_object(index, object, object_id),
    do: partial_update_object(index, object, object_id, upsert?: true)
  def partial_update_object(index, object, object_id, upsert?: upsert) do
    body = object |> Poison.encode!

    params = if upsert do
      ""
    else
      "?createIfNotExists=false"
    end

    path = "#{index}/#{object_id}/partial" <> URI.encode(params)

    send_request(:write, :post, path, body)
    |> inject_index_into_response(index)
  end

  # No need to add any objectID by default
  defp add_object_ids(objects, id_attribute: :objectID), do: objects
  defp add_object_ids(objects, id_attribute: "objectID"), do: objects
  defp add_object_ids(objects, id_attribute: attribute) do
    Enum.map(objects, fn(object) ->
      object_id = object[attribute] || object[to_string attribute]

      if !object_id do
        raise ArgumentError, message: "id attribute `#{attribute}` doesn't exist"
      end

      add_object_id(object, object_id)
    end)
  end

  defp add_object_id(object, object_id) do
    Map.put(object, :objectID, object_id)
  end

  defp get_object_id(object) do
    case object[:objectID] || object["objectID"] do
      nil -> {:error, "Not objectID found"}
      object_id -> {:ok, object_id}
    end
  end

  defp get_object_id!(object) do
    case get_object_id(object) do
      {:error, _} ->
        raise ArgumentError, message: "objectID doesn't exist"
      {:ok, object_id} -> object_id
    end
  end

  defp send_batch_request(requests, index) do
    path = "/#{index}/batch"
    body = requests |> Poison.encode!

    send_request(:write, :post, path, body)
    |> inject_index_into_response(index)
  end

  defp build_batch_request(objects, action, with_object_id: with_object_id) do
    requests = Enum.map objects, fn(object) ->
      if with_object_id do
        object_id = get_object_id!(object)

        %{action: action, body: object, objectID: object_id}
      else
        %{action: action, body: object}
      end
    end

    %{ requests: requests }
  end

  @doc """
  Delete a object by its objectID
  """
  def delete_object(index, object_id) do
    path = "#{index}/#{object_id}"
    send_request(:write, :delete, path)
    |> inject_index_into_response(index)
  end

  @doc """
  Delete multiple objects
  """
  def delete_objects(index, object_ids) do
    object_ids
    |> Enum.map(fn (id) ->
      %{objectID: id}
    end)
    |> build_batch_request("deleteObject", with_object_id: true)
    |> send_batch_request(index)
  end

  @doc """
  Clears all content of an index
  """
  def clear_index(index) do
    path = "#{index}/clear"
    send_request(:write, :post, path)
    |> inject_index_into_response(index)
  end

  @doc """
  Set the settings of a index
  """
  def set_settings(index, settings) do
    body = settings |> Poison.encode!
    send_request(:write, :put, "/#{index}/settings", body)
    |> inject_index_into_response(index)
  end

  @doc """
  Get the settings of a index
  """
  def get_settings(index) do
    send_request(:read, :get, "/#{index}/settings")
    |> inject_index_into_response(index)
  end

  @doc """
  Moves an index to new one
  """
  def move_index(src_index, dst_index) do
    body = %{ operation: "move", destination: dst_index } |> Poison.encode!
    send_request(:write, :post, "/#{src_index}/operation", body)
    |> inject_index_into_response(src_index)
  end

  @doc """
  Copies an index to a new one
  """
  def copy_index(src_index, dst_index) do
    body = %{ operation: "copy", destination: dst_index } |> Poison.encode!
    send_request(:write, :post, "/#{src_index}/operation", body)
    |> inject_index_into_response(src_index)
  end

  ## Helps piping a response into wait_task, as it requires the index
  defp inject_index_into_response({:ok, body}, index) do
    {:ok, Map.put(body, "indexName", index)}
  end
  defp inject_index_into_response(response, index), do: response

  @doc """
  Wait for a task for an index to complete
  returns :ok when it's done
  """
  def wait_task(index, task_id, time_before_retry \\ 1000) do
    case send_request(:write, :get, "#{index}/task/#{task_id}") do
      {:ok, %{"status" => "published"}} -> :ok
      {:ok, %{"status" => "notPublished"}} ->
        :timer.sleep(time_before_retry)
        wait_task(index, task_id, time_before_retry)
      other -> other
    end
  end

  @doc """
  Convinient version of wait_task/4, accepts a response to be waited on
  directly. This enables piping a operation directly into wait_task
  """
  def wait(response = {:ok, %{"indexName" => index, "taskID" => task_id}}, time_before_retry) do
    with :ok <- wait_task(index, task_id, time_before_retry), do: response
  end
  def wait(response = {:ok, _}), do: wait(response, 1000)
  def wait(response), do: response
end