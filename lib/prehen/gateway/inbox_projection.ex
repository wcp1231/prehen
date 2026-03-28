defmodule Prehen.Gateway.InboxProjection do
  @moduledoc false

  use GenServer

  @type session_row :: %{
          session_id: String.t(),
          agent_name: String.t() | nil,
          status: atom(),
          created_at: integer() | nil,
          last_event_at: integer() | nil,
          preview: String.t() | nil
        }

  @type history_entry :: %{
          id: String.t(),
          kind: :user_message | :assistant_message,
          session_id: String.t(),
          message_id: String.t() | nil,
          text: String.t(),
          timestamp: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec list_sessions() :: [session_row()]
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec session_started(map()) :: :ok | {:error, :invalid_attrs}
  def session_started(attrs), do: GenServer.call(__MODULE__, {:session_started, attrs})

  @spec user_message(map()) :: :ok | {:error, :invalid_attrs | :not_found}
  def user_message(attrs), do: GenServer.call(__MODULE__, {:user_message, attrs})

  @spec agent_delta(map()) :: :ok | {:error, :invalid_attrs | :not_found}
  def agent_delta(attrs), do: GenServer.call(__MODULE__, {:agent_delta, attrs})

  @spec agent_completed(map()) :: :ok | {:error, :invalid_attrs | :not_found}
  def agent_completed(attrs), do: GenServer.call(__MODULE__, {:agent_completed, attrs})

  @spec session_stopped(map()) :: :ok | {:error, :invalid_attrs | :not_found}
  def session_stopped(attrs), do: GenServer.call(__MODULE__, {:session_stopped, attrs})

  @spec fetch_session(String.t()) :: {:ok, session_row()} | {:error, :not_found}
  def fetch_session(session_id), do: GenServer.call(__MODULE__, {:fetch_session, session_id})

  @spec fetch_history(String.t()) :: {:ok, [history_entry()]} | {:error, :not_found}
  def fetch_history(session_id), do: GenServer.call(__MODULE__, {:fetch_history, session_id})

  @impl true
  def init(_opts), do: {:ok, empty_state()}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

  def handle_call(:list_sessions, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.sort_by(&{&1.last_event_at || &1.created_at || 0, &1.created_at || 0}, :desc)

    {:reply, sessions, state}
  end

  def handle_call({:session_started, attrs}, _from, state) do
    with {:ok, session_id} <- fetch_required_binary(attrs, :session_id),
         :ok <- validate_optional_integer(attrs, :created_at),
         :ok <- validate_optional_agent_name(attrs) do
      case Map.has_key?(state.sessions, session_id) do
        true ->
          {:reply, :ok, state}

        false ->
          created_at = Map.get(attrs, :created_at)

          row = %{
            session_id: session_id,
            agent_name: Map.get(attrs, :agent_name),
            status: :attached,
            created_at: created_at,
            last_event_at: created_at,
            preview: nil
          }

          next_state =
            state
            |> put_session(row)
            |> ensure_history(session_id)

          {:reply, :ok, next_state}
      end
    else
      :error -> {:reply, {:error, :invalid_attrs}, state}
      {:error, :invalid_attrs} -> {:reply, {:error, :invalid_attrs}, state}
    end
  end

  def handle_call({:user_message, attrs}, _from, state) do
    with {:ok, session_id} <- fetch_required_binary(attrs, :session_id),
         {:ok, message_id} <- fetch_required_binary(attrs, :message_id),
         {:ok, text} <- fetch_optional_text(attrs) do
      case Map.has_key?(state.sessions, session_id) do
        false ->
          {:reply, {:error, :not_found}, state}

        true ->
          {timestamp, next_state} = next_timestamp(state, session_id)

          entry = %{
            id: next_history_id(),
            kind: :user_message,
            session_id: session_id,
            message_id: message_id,
            text: text,
            timestamp: timestamp
          }

          next_state =
            next_state
            |> ensure_history(session_id)
            |> append_history(session_id, entry)
            |> update_session_row(session_id, entry, status: :running)

          {:reply, :ok, next_state}
      end
    else
      :error -> {:reply, {:error, :invalid_attrs}, state}
      {:error, :invalid_attrs} -> {:reply, {:error, :invalid_attrs}, state}
    end
  end

  def handle_call({:agent_delta, attrs}, _from, state) do
    with {:ok, session_id} <- fetch_required_binary(attrs, :session_id),
         {:ok, message_id} <- fetch_required_binary(attrs, :message_id),
         {:ok, text} <- fetch_optional_text(attrs) do
      case Map.has_key?(state.sessions, session_id) do
        false ->
          {:reply, {:error, :not_found}, state}

        true ->
          {timestamp, next_state} = next_timestamp(state, session_id)

          next_state =
            next_state
            |> ensure_history(session_id)
            |> merge_assistant_delta(session_id, message_id, text, timestamp)
            |> update_session_from_latest_history(session_id)

          {:reply, :ok, next_state}
      end
    else
      :error -> {:reply, {:error, :invalid_attrs}, state}
      {:error, :invalid_attrs} -> {:reply, {:error, :invalid_attrs}, state}
    end
  end

  def handle_call({:agent_completed, attrs}, _from, state) do
    with {:ok, session_id} <- fetch_required_binary(attrs, :session_id),
         {:ok, _message_id} <- fetch_required_binary(attrs, :message_id) do
      case Map.has_key?(state.sessions, session_id) do
        false ->
          {:reply, {:error, :not_found}, state}

        true ->
          next_state = update_session_status(state, session_id, :idle)
          {:reply, :ok, next_state}
      end
    else
      :error -> {:reply, {:error, :invalid_attrs}, state}
      {:error, :invalid_attrs} -> {:reply, {:error, :invalid_attrs}, state}
    end
  end

  def handle_call({:session_stopped, attrs}, _from, state) do
    with {:ok, session_id} <- fetch_required_binary(attrs, :session_id),
         {:ok, status} <- fetch_terminal_status(attrs) do
      case Map.has_key?(state.sessions, session_id) do
        false ->
          now_ms = System.system_time(:millisecond)

          row = %{
            session_id: session_id,
            agent_name: Map.get(attrs, :agent_name),
            status: status,
            created_at: nil,
            last_event_at: now_ms,
            preview: nil
          }

          next_state =
            state
            |> put_session(row)
            |> ensure_history(session_id)

          {:reply, :ok, next_state}

        true ->
          next_state = update_session_status(state, session_id, status)
          {:reply, :ok, next_state}
      end
    else
      :error -> {:reply, {:error, :invalid_attrs}, state}
      {:error, :invalid_attrs} -> {:reply, {:error, :invalid_attrs}, state}
    end
  end

  def handle_call({:fetch_session, session_id}, _from, state) do
    reply =
      case Map.fetch(state.sessions, session_id) do
        {:ok, row} -> {:ok, row}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:fetch_history, session_id}, _from, state) do
    reply =
      case Map.fetch(state.history, session_id) do
        {:ok, history} -> {:ok, history}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp empty_state do
    %{sessions: %{}, history: %{}}
  end

  defp ensure_history(state, session_id) do
    update_in(state.history, fn history -> Map.put_new(history, session_id, []) end)
  end

  defp put_session(state, row) do
    put_in(state.sessions[row.session_id], row)
  end

  defp append_history(state, session_id, entry) do
    update_in(state.history[session_id], fn history -> history ++ [entry] end)
  end

  defp merge_assistant_delta(state, session_id, message_id, text, timestamp) do
    update_in(state.history[session_id], fn history ->
      case Enum.find_index(history, &assistant_message_match?(&1, message_id)) do
        nil ->
          history ++
            [
              %{
                id: next_history_id(),
                kind: :assistant_message,
                session_id: session_id,
                message_id: message_id,
                text: text,
                timestamp: timestamp
              }
            ]

        index ->
          {before, [entry | trailing]} = Enum.split(history, index)
          before ++ trailing ++ [%{entry | text: entry.text <> text, timestamp: timestamp}]
      end
    end)
  end

  defp update_session_row(state, session_id, entry, opts \\ []) do
    update_in(state.sessions[session_id], fn
      nil ->
        nil

      row ->
        row
        |> Map.put(:preview, entry.text)
        |> Map.put(:last_event_at, entry.timestamp)
        |> maybe_put_status(Keyword.get(opts, :status))
    end)
  end

  defp update_session_from_latest_history(state, session_id) do
    latest_entry = state.history |> Map.fetch!(session_id) |> List.last()
    update_session_row(state, session_id, latest_entry)
  end

  defp next_timestamp(state, session_id) do
    session = Map.get(state.sessions, session_id, %{})
    base_timestamp = Map.get(session, :last_event_at) || System.system_time(:millisecond)
    {max(System.system_time(:millisecond), base_timestamp + 1), state}
  end

  defp next_history_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
    |> then(&("history_" <> &1))
  end

  defp assistant_message_match?(
         %{kind: :assistant_message, message_id: message_id},
         target_message_id
       ) do
    message_id == target_message_id
  end

  defp assistant_message_match?(_entry, _target_message_id), do: false

  defp update_session_status(state, session_id, status) do
    update_in(state.sessions[session_id], fn
      nil -> nil
      row -> %{row | status: status}
    end)
  end

  defp maybe_put_status(row, nil), do: row
  defp maybe_put_status(row, status), do: Map.put(row, :status, status)

  defp fetch_required_binary(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_required_binary(_attrs, _key), do: :error

  defp fetch_optional_text(attrs) when is_map(attrs) do
    case Map.get(attrs, :text, "") do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_attrs}
    end
  end

  defp fetch_optional_text(_attrs), do: {:error, :invalid_attrs}

  defp validate_optional_integer(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) -> :ok
      _ -> {:error, :invalid_attrs}
    end
  end

  defp validate_optional_integer(_attrs, _key), do: {:error, :invalid_attrs}

  defp validate_optional_agent_name(attrs) when is_map(attrs) do
    case Map.fetch(attrs, :agent_name) do
      :error -> :ok
      {:ok, value} when is_binary(value) or is_nil(value) -> :ok
      _ -> {:error, :invalid_attrs}
    end
  end

  defp validate_optional_agent_name(_attrs), do: {:error, :invalid_attrs}

  defp fetch_terminal_status(attrs) when is_map(attrs) do
    case Map.get(attrs, :status, :stopped) do
      status when status in [:stopped, :crashed] -> {:ok, status}
      _ -> {:error, :invalid_attrs}
    end
  end

  defp fetch_terminal_status(_attrs), do: {:error, :invalid_attrs}
end
