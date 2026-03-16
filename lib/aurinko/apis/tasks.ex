defmodule Aurinko.API.Tasks do
  @moduledoc """
  Aurinko Tasks API — manage task lists and todos.

  Supports Google Tasks, Microsoft To Do, and Exchange Tasks.
  """

  alias Aurinko.Error
  alias Aurinko.HTTP.Client
  alias Aurinko.Types.{Pagination, Task}

  @doc "List all task lists."
  @spec list_task_lists(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, Error.t()}
  def list_task_lists(token, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token]) |> camelize_params()

    case Client.get(token, "/tasks/lists", params: params) do
      {:ok, body} ->
        {:ok, body["records"] || []}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  List tasks in a task list.

  ## Options

  - `:limit` — Number of results
  - `:page_token` — Pagination token
  - `:status` — Filter by status (`"notStarted"`, `"inProgress"`, `"completed"`)
  """
  @spec list_tasks(String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def list_tasks(token, task_list_id, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token, :status]) |> camelize_params()

    case Client.get(token, "/tasks/lists/#{task_list_id}/tasks", params: params) do
      {:ok, body} ->
        {:ok, Pagination.from_response(body)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a task.

  ## Parameters

  - `:title` — Task title (required)
  - `:body` — Task description
  - `:due` — Due date (DateTime)
  - `:importance` — `"low"`, `"normal"`, or `"high"`
  - `:status` — `"notStarted"`, `"inProgress"`, or `"completed"`
  """
  @spec create_task(String.t(), String.t(), map()) ::
          {:ok, Task.t()} | {:error, Error.t()}
  def create_task(token, task_list_id, %{title: _} = params) do
    body = build_task_body(params)

    case Client.post(token, "/tasks/lists/#{task_list_id}/tasks", body) do
      {:ok, resp} ->
        {:ok, Task.from_response(resp)}

      {:error, _} = err ->
        err
    end
  end

  def create_task(_token, _list_id, _),
    do: {:error, Error.invalid_params("`:title` is required")}

  @doc "Update a task."
  @spec update_task(String.t(), String.t(), String.t(), map()) ::
          {:ok, Task.t()} | {:error, Error.t()}
  def update_task(token, task_list_id, task_id, params) do
    body = build_task_body(params)

    case Client.patch(token, "/tasks/lists/#{task_list_id}/tasks/#{task_id}", body) do
      {:ok, resp} ->
        {:ok, Task.from_response(resp)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Delete a task."
  @spec delete_task(String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def delete_task(token, task_list_id, task_id) do
    case Client.delete(token, "/tasks/lists/#{task_list_id}/tasks/#{task_id}") do
      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp build_task_body(params) do
    %{}
    |> maybe_put(:title, params[:title])
    |> maybe_put(:body, params[:body])
    |> maybe_put(:status, params[:status])
    |> maybe_put(:importance, params[:importance])
    |> maybe_put(:dueDateTime, format_due(params[:due]))
  end

  defp format_due(nil), do: nil
  defp format_due(%DateTime{} = dt), do: %{"dateTime" => DateTime.to_iso8601(dt)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp camelize_params(kw), do: Enum.map(kw, fn {k, v} -> {camelize(k), v} end)
  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(str) when is_binary(str) do
    [first | rest] = String.split(str, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end
end
