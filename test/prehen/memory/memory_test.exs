defmodule Prehen.MemoryTest do
  use ExUnit.Case

  alias Prehen.Memory

  defmodule FailingAdapter do
    @behaviour Prehen.Memory.LTM.Adapter

    @impl true
    def get(_session_id, _query), do: {:error, :ltm_unavailable}

    @impl true
    def put(_session_id, _entry, _meta), do: {:error, :ltm_unavailable}
  end

  test "session stm keeps buffer, working context and token budget" do
    session_id = unique_session_id("stm")

    assert {:ok, _} = Memory.ensure_session(session_id, buffer_limit: 2, token_budget_limit: 20)
    assert {:ok, _} = Memory.put_working_context(session_id, %{topic: "architecture"})
    assert {:ok, _} = Memory.record_turn(session_id, %{input: "hello", output: "world"})
    assert {:ok, _} = Memory.record_turn(session_id, %{input: "follow-up", output: "answer"})
    assert {:ok, _} = Memory.record_turn(session_id, %{input: "third", output: "answer-3"})

    assert {:ok, context} = Memory.context(session_id)
    assert context.source == :stm_only
    assert context.ltm == nil
    assert context.ltm_error == nil
    assert length(context.stm.conversation_buffer) == 2
    assert context.stm.working_context.topic == "architecture"
    assert context.stm.token_budget.limit == 20
    assert context.stm.token_budget.used > 0
    assert context.stm.token_budget.remaining >= 0
  end

  test "ltm read failures degrade to stm-only context" do
    session_id = unique_session_id("degraded")
    assert {:ok, _} = Memory.record_turn(session_id, %{input: "question", output: "answer"})

    assert {:ok, context} = Memory.context(session_id, ltm_adapter: FailingAdapter)
    assert context.source == :stm_ltm_degraded
    assert context.ltm == nil
    assert context.ltm_error == :ltm_unavailable
    assert length(context.stm.conversation_buffer) == 1
  end

  test "ltm write failure does not block stm updates" do
    session_id = unique_session_id("write-failure")

    assert {:ok, result} =
             Memory.record_turn(session_id, %{input: "persist", output: "ok"},
               ltm_adapter: FailingAdapter
             )

    assert result.ltm_write == {:error, :ltm_unavailable}

    assert {:ok, context} = Memory.context(session_id)
    assert context.source == :stm_only
    assert length(context.stm.conversation_buffer) == 1
  end

  defp unique_session_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
