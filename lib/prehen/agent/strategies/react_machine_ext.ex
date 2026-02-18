defmodule Prehen.Agent.Strategies.ReactMachineExt do
  @moduledoc false

  @spec ensure(map()) :: map()
  def ensure(state) when is_map(state) do
    state
    |> Map.put_new(:prompt_q, [])
    |> Map.put_new(:steer_q, [])
    |> Map.put_new(:followup_q, [])
    |> Map.put_new(:turn_phase, :idle)
    |> Map.put_new(:skipped_tool_calls, [])
    |> sync_from_base()
  end

  @spec enqueue(map(), :prompt | :steer | :followup, map()) :: map()
  def enqueue(state, kind, item) when kind in [:prompt, :steer, :followup] and is_map(item) do
    key =
      case kind do
        :prompt -> :prompt_q
        :steer -> :steer_q
        :followup -> :followup_q
      end

    Map.update(state, key, [item], fn list -> list ++ [item] end)
  end

  @spec dequeue_next(map()) :: {:none, map()} | {map(), map()}
  def dequeue_next(state) when is_map(state) do
    cond do
      state[:steer_q] != [] ->
        [item | rest] = state[:steer_q]
        {item, %{state | steer_q: rest}}

      state[:prompt_q] != [] ->
        [item | rest] = state[:prompt_q]
        {item, %{state | prompt_q: rest}}

      state[:followup_q] != [] ->
        [item | rest] = state[:followup_q]
        {item, %{state | followup_q: rest}}

      true ->
        {:none, state}
    end
  end

  @spec busy?(map()) :: boolean()
  def busy?(state) when is_map(state) do
    state[:status] in [:awaiting_llm, :awaiting_tool]
  end

  @spec ready_for_next?(map()) :: boolean()
  def ready_for_next?(state) when is_map(state) do
    state[:status] in [:idle, :completed, :error] and has_queued?(state)
  end

  @spec has_queued?(map()) :: boolean()
  def has_queued?(state) when is_map(state) do
    state[:prompt_q] != [] or state[:steer_q] != [] or state[:followup_q] != []
  end

  @spec sync_from_base(map()) :: map()
  def sync_from_base(state) when is_map(state) do
    pending = state[:pending_tool_calls] || []

    phase =
      case state[:status] do
        :awaiting_llm -> :llm
        :awaiting_tool -> :tools
        :completed -> :finalizing
        :error -> :finalizing
        _ -> :idle
      end

    state
    |> Map.put(:turn_phase, phase)
    |> Map.put(:pending_tool_calls, pending)
  end

  @spec unresolved_tool_calls(map()) :: [map()]
  def unresolved_tool_calls(state) when is_map(state) do
    (state[:pending_tool_calls] || [])
    |> Enum.filter(fn tool ->
      is_map(tool) and is_binary(tool[:id] || tool["id"]) and
        is_nil(tool[:result] || tool["result"])
    end)
    |> Enum.map(&normalize_tool/1)
  end

  defp normalize_tool(tool) do
    %{
      id: tool[:id] || tool["id"],
      name: tool[:name] || tool["name"],
      arguments: tool[:arguments] || tool["arguments"] || %{}
    }
  end
end
