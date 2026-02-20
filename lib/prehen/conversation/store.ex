defmodule Prehen.Conversation.Store do
  @moduledoc """
  Canonical conversation/event store（append-only）。

  中文：
  - 按 `session_id` 维护统一事实流（event + message）。
  - 写入时自动分配顺序号 `seq`，支持按条件回放。
  - 先持久化到 ledger，再发布到 projection 总线。

  English:
  - Canonical append-only store for session conversation/events.
  - Persists ordered records with per-session `seq`.
  - Persists-first then publishes to projection consumers.
  """

  use GenServer

  alias Prehen.Conversation.SessionLedger
  alias Prehen.Events.ProjectionSupervisor

  @type entry :: map()
  @type record :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec write(String.t(), entry()) :: {:ok, record()} | {:error, term()}
  def write(session_id, entry) when is_binary(session_id) and is_map(entry) do
    GenServer.call(__MODULE__, {:write, session_id, entry})
  end

  @spec write_many(String.t(), [entry()]) :: {:ok, [record()]} | {:error, term()}
  def write_many(session_id, entries) when is_binary(session_id) and is_list(entries) do
    GenServer.call(__MODULE__, {:write_many, session_id, entries})
  end

  @spec append(String.t(), entry()) :: :ok
  def append(session_id, event) when is_binary(session_id) and is_map(event) do
    case write(session_id, event) do
      {:ok, _record} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec append_many(String.t(), [entry()]) :: :ok
  def append_many(session_id, events) when is_binary(session_id) and is_list(events) do
    case write_many(session_id, events) do
      {:ok, _records} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec replay(String.t(), keyword()) :: [record()]
  def replay(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    case replay_result(session_id, opts) do
      {:ok, records} -> records
      {:error, _reason} -> []
    end
  end

  @spec replay_result(String.t(), keyword()) :: {:ok, [record()]} | {:error, term()}
  def replay_result(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    GenServer.call(__MODULE__, {:replay_result, session_id, opts})
  end

  @spec replay_error(String.t()) :: {:ok, term()} | :none
  def replay_error(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:replay_error, session_id})
  end

  @spec health() :: map()
  def health do
    if Process.whereis(__MODULE__) do
      %{status: :up}
    else
      %{status: :down}
    end
  end

  @impl true
  def init(_state) do
    {:ok, %{next_seq: %{}, replay_errors: %{}}}
  end

  @impl true
  def handle_call({:write, session_id, entry}, _from, state) do
    case append_record(state, session_id, entry) do
      {:ok, record, next_state} ->
        {:reply, {:ok, record}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:write_many, session_id, entries}, _from, state) do
    normalized = Enum.filter(entries, &is_map/1)

    {result, next_state} =
      Enum.reduce_while(normalized, {{:ok, []}, state}, fn entry, {{:ok, acc}, acc_state} ->
        case append_record(acc_state, session_id, entry) do
          {:ok, record, state_after_write} ->
            {:cont, {{:ok, [record | acc]}, state_after_write}}

          {:error, reason, state_after_write} ->
            {:halt, {{:error, reason}, state_after_write}}
        end
      end)

    case result do
      {:ok, records} ->
        {:reply, {:ok, Enum.reverse(records)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:replay_result, session_id, opts}, _from, state) do
    case load_records(state, session_id) do
      {:ok, records, next_state} ->
        filtered =
          records
          |> filter_by_seq(Keyword.get(opts, :from_seq, 1))
          |> filter_by_kind(Keyword.get(opts, :kind))

        {:reply, {:ok, filtered}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:replay_error, session_id}, _from, state) do
    case Map.fetch(state.replay_errors, session_id) do
      {:ok, reason} -> {:reply, {:ok, reason}, state}
      :error -> {:reply, :none, state}
    end
  end

  defp append_record(state, session_id, entry) do
    with {:ok, seq, state_after_seq} <- resolve_next_seq(state, session_id),
         record <- build_record(seq, session_id, entry),
         {:ok, _record} <- SessionLedger.append(session_id, record),
         :ok <- maybe_checkpoint(record),
         :ok <- safe_publish(record) do
      next_state =
        state_after_seq
        |> put_next_seq(session_id, seq + 1)
        |> clear_replay_error(session_id)

      {:ok, record, next_state}
    else
      {:error, reason} ->
        {:error, reason, put_replay_error(state, session_id, reason)}
    end
  end

  defp load_records(state, session_id) do
    case SessionLedger.replay(session_id) do
      {:ok, records} ->
        next_seq =
          case List.last(records) do
            nil -> 1
            record -> map_get(record, :seq, 0) + 1
          end

        next_state =
          state
          |> put_next_seq(session_id, next_seq)
          |> clear_replay_error(session_id)

        {:ok, records, next_state}

      {:error, reason} ->
        {:error, reason, put_replay_error(state, session_id, reason)}
    end
  end

  defp resolve_next_seq(state, session_id) do
    case Map.fetch(state.next_seq, session_id) do
      {:ok, next_seq} ->
        {:ok, next_seq, state}

      :error ->
        case load_records(state, session_id) do
          {:ok, records, next_state} ->
            seq =
              case List.last(records) do
                nil -> 1
                record -> map_get(record, :seq, 0) + 1
              end

            {:ok, seq, next_state}

          {:error, reason, next_state} ->
            {:error, reason, next_state}
        end
    end
  end

  defp put_next_seq(state, session_id, next_seq) do
    put_in(state, [:next_seq, session_id], next_seq)
  end

  defp put_replay_error(state, session_id, reason) do
    put_in(state, [:replay_errors, session_id], reason)
  end

  defp clear_replay_error(state, session_id) do
    %{state | replay_errors: Map.delete(state.replay_errors, session_id)}
  end

  defp maybe_checkpoint(record) do
    if map_get(record, :type) == "ai.session.turn.completed" do
      SessionLedger.sync(map_get(record, :session_id))
    else
      :ok
    end
  end

  defp build_record(seq, session_id, entry) do
    now = System.system_time(:millisecond)
    normalized = normalize_entry(entry, now)

    normalized
    |> Map.put(:session_id, session_id)
    |> Map.put(:seq, seq)
    |> Map.put_new(:stored_at_ms, now)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_entry(entry, now) do
    kind =
      cond do
        is_binary(map_get(entry, :type)) -> :event
        not is_nil(map_get(entry, :role)) -> :message
        true -> normalize_kind(map_get(entry, :kind, :record))
      end

    entry
    |> Map.put(:kind, kind)
    |> Map.put_new(:at_ms, now)
  end

  defp normalize_kind(kind) when kind in [:event, :message, :record], do: kind
  defp normalize_kind("event"), do: :event
  defp normalize_kind("message"), do: :message
  defp normalize_kind(_), do: :record

  defp safe_publish(record) do
    _ = ProjectionSupervisor.publish(record)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp filter_by_seq(records, from_seq) when is_integer(from_seq) and from_seq > 1 do
    Enum.filter(records, &(map_get(&1, :seq, 0) >= from_seq))
  end

  defp filter_by_seq(records, _from_seq), do: records

  defp filter_by_kind(records, kind) when kind in [:event, :message, :record] do
    Enum.filter(records, &(map_get(&1, :kind) == kind))
  end

  defp filter_by_kind(records, _kind), do: records

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default
end
