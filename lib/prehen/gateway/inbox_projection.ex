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
          kind: :user_message | :assistant_message,
          session_id: String.t(),
          message_id: String.t(),
          text: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec list_sessions() :: [session_row()]
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec session_started(map()) :: :ok
  def session_started(attrs), do: GenServer.call(__MODULE__, {:session_started, attrs})

  @spec user_message(map()) :: :ok
  def user_message(attrs), do: GenServer.call(__MODULE__, {:user_message, attrs})

  @spec agent_delta(map()) :: :ok
  def agent_delta(attrs), do: GenServer.call(__MODULE__, {:agent_delta, attrs})

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
    session_id = Map.fetch!(attrs, :session_id)
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

  def handle_call({:user_message, attrs}, _from, state) do
    session_id = Map.fetch!(attrs, :session_id)

    entry = %{
      kind: :user_message,
      session_id: session_id,
      message_id: Map.fetch!(attrs, :message_id),
      text: Map.get(attrs, :text, "")
    }

    next_state =
      state
      |> ensure_history(session_id)
      |> append_history(session_id, entry)

    {:reply, :ok, next_state}
  end

  def handle_call({:agent_delta, attrs}, _from, state) do
    session_id = Map.fetch!(attrs, :session_id)
    message_id = Map.fetch!(attrs, :message_id)
    text = Map.get(attrs, :text, "")

    next_state =
      state
      |> ensure_history(session_id)
      |> merge_assistant_delta(session_id, message_id, text)
      |> update_preview(session_id)

    {:reply, :ok, next_state}
  end

  def handle_call({:fetch_session, session_id}, _from, state) do
    {:reply, Map.fetch(state.sessions, session_id), state}
  end

  def handle_call({:fetch_history, session_id}, _from, state) do
    {:reply, Map.fetch(state.history, session_id), state}
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

  defp merge_assistant_delta(state, session_id, message_id, text) do
    update_in(state.history[session_id], fn history ->
      case Enum.split(history, -1) do
        {prefix, [%{kind: :assistant_message, message_id: ^message_id} = last]} ->
          prefix ++ [%{last | text: last.text <> text}]

        _ ->
          history ++
            [
              %{
                kind: :assistant_message,
                session_id: session_id,
                message_id: message_id,
                text: text
              }
            ]
      end
    end)
  end

  defp update_preview(state, session_id) do
    preview =
      state.history
      |> Map.fetch!(session_id)
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{kind: :assistant_message, text: text} -> text
        _ -> nil
      end)

    update_in(state.sessions[session_id], fn
      nil -> nil
      row -> %{row | preview: preview}
    end)
  end
end
