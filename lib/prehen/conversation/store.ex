defmodule Prehen.Conversation.Store do
  @moduledoc """
  Canonical conversation/event store（append-only）。

  中文：
  - 按 `session_id` 维护统一事实流（event + message）。
  - 写入时自动分配顺序号 `seq`，支持按条件回放。
  - 每次写入都会发布到 projection 总线供 CLI/日志/指标消费。

  English:
  - Canonical append-only store for session conversation/events.
  - Persists ordered records with per-session `seq`.
  - Supports filtered replay and publishes records to projection consumers.
  """

  use GenServer

  alias Prehen.Events.ProjectionSupervisor

  @type entry :: map()
  @type record :: map()
  @type session_stream :: %{next_seq: pos_integer(), records: [record()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec write(String.t(), entry()) :: {:ok, record()}
  def write(session_id, entry) when is_binary(session_id) and is_map(entry) do
    GenServer.call(__MODULE__, {:write, session_id, entry})
  end

  @spec write_many(String.t(), [entry()]) :: {:ok, [record()]}
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
    GenServer.call(__MODULE__, {:replay, session_id, opts})
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
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:write, session_id, entry}, _from, state) do
    {record, next_state} = append_record(state, session_id, entry)
    {:reply, {:ok, record}, next_state}
  end

  def handle_call({:write_many, session_id, entries}, _from, state) do
    normalized = Enum.filter(entries, &is_map/1)

    {records, next_state} =
      Enum.reduce(normalized, {[], state}, fn entry, {acc, acc_state} ->
        {record, next} = append_record(acc_state, session_id, entry)
        {[record | acc], next}
      end)

    {:reply, {:ok, Enum.reverse(records)}, next_state}
  end

  def handle_call({:replay, session_id, opts}, _from, state) do
    stream = Map.get(state, session_id, empty_stream())

    records =
      stream.records
      |> filter_by_seq(Keyword.get(opts, :from_seq, 1))
      |> filter_by_kind(Keyword.get(opts, :kind))

    {:reply, records, state}
  end

  defp append_record(state, session_id, entry) do
    stream = Map.get(state, session_id, empty_stream())
    record = build_record(stream.next_seq, session_id, entry)

    next_stream = %{
      next_seq: stream.next_seq + 1,
      records: stream.records ++ [record]
    }

    next_state = Map.put(state, session_id, next_stream)
    safe_publish(record)
    {record, next_state}
  end

  defp build_record(seq, session_id, entry) do
    now = System.system_time(:millisecond)
    normalized = normalize_entry(entry, now)

    normalized
    |> Map.put_new(:session_id, session_id)
    |> Map.put_new(:seq, seq)
    |> Map.put_new(:stored_at_ms, now)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_entry(entry, now) do
    kind =
      cond do
        is_binary(map_get(entry, :type)) -> :event
        not is_nil(map_get(entry, :role)) -> :message
        true -> map_get(entry, :kind, :record)
      end

    entry
    |> Map.put_new(:kind, kind)
    |> Map.put_new(:at_ms, now)
  end

  defp safe_publish(record) do
    _ = ProjectionSupervisor.publish(record)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp empty_stream do
    %{next_seq: 1, records: []}
  end

  defp filter_by_seq(records, from_seq) when is_integer(from_seq) and from_seq > 1 do
    Enum.filter(records, &(&1.seq >= from_seq))
  end

  defp filter_by_seq(records, _from_seq), do: records

  defp filter_by_kind(records, kind) when kind in [:event, :message, :record] do
    Enum.filter(records, &(&1.kind == kind))
  end

  defp filter_by_kind(records, _kind), do: records

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default
end
