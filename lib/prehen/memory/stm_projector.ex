defmodule Prehen.Memory.STMProjector do
  @moduledoc false

  alias Prehen.Memory.STM

  @summary_event_type "ai.session.turn.summary"

  @spec rebuild(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(session_id, records, opts \\ [])
      when is_binary(session_id) and is_list(records) and is_list(opts) do
    summaries =
      records
      |> Enum.filter(&summary_record?/1)
      |> Enum.sort_by(&map_get(&1, :turn_id, 0))

    with :ok <- validate_summaries(summaries),
         {:ok, _memory} <- STM.reset_session(session_id, opts),
         {:ok, turn_seq} <- apply_summaries(session_id, summaries, opts),
         {:ok, stm} <- STM.get(session_id) do
      {:ok,
       %{
         session_id: session_id,
         turn_seq: turn_seq,
         summary_count: length(summaries),
         stm: stm
       }}
    end
  end

  defp summary_record?(record) when is_map(record) do
    map_get(record, :kind) == :event and map_get(record, :type) == @summary_event_type
  end

  defp summary_record?(_record), do: false

  defp validate_summaries(summaries) do
    turn_ids = Enum.map(summaries, &map_get(&1, :turn_id))

    cond do
      Enum.any?(turn_ids, fn turn_id -> not (is_integer(turn_id) and turn_id > 0) end) ->
        {:error, {:invalid_summary_turn_id, turn_ids}}

      turn_ids != Enum.uniq(turn_ids) ->
        {:error, {:duplicate_summary_turn_id, turn_ids}}

      true ->
        :ok
    end
  end

  defp apply_summaries(session_id, summaries, opts) do
    Enum.reduce_while(summaries, {:ok, 0}, fn summary, {:ok, _last_turn_id} ->
      turn_id = map_get(summary, :turn_id, 0)

      turn = %{
        source: "session",
        turn_id: turn_id,
        kind: :prompt,
        input: map_get(summary, :input, ""),
        answer: map_get(summary, :answer, ""),
        status: normalize_status(map_get(summary, :status, :ok)),
        tool_calls: normalize_tool_calls(map_get(summary, :tool_calls, [])),
        at_ms: map_get(summary, :at_ms)
      }

      working_context = normalize_working_context(map_get(summary, :working_context, %{}))

      with {:ok, _memory} <- STM.record_turn(session_id, compact_map(turn), opts),
           {:ok, _memory} <- maybe_put_working_context(session_id, working_context, opts) do
        {:cont, {:ok, turn_id}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_put_working_context(_session_id, working_context, _opts)
       when map_size(working_context) == 0 do
    {:ok, %{}}
  end

  defp maybe_put_working_context(session_id, working_context, opts) do
    STM.put_working_context(session_id, working_context, opts)
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls),
    do: Enum.filter(tool_calls, &is_map/1)

  defp normalize_tool_calls(_), do: []

  defp normalize_working_context(working_context) when is_map(working_context),
    do: working_context

  defp normalize_working_context(_), do: %{}

  defp normalize_status(status) when status in [:ok, :error, :failed], do: status
  defp normalize_status("ok"), do: :ok
  defp normalize_status("error"), do: :error
  defp normalize_status("failed"), do: :failed
  defp normalize_status(_), do: :ok

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default
end
