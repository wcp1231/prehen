defmodule Prehen.Agent.OrchestratorTest do
  use ExUnit.Case

  alias Prehen.Agent.Orchestrator
  alias Prehen.Agent.Roles.Coordinator
  alias Prehen.Agent.Orchestrator.Routers

  test "rule router sends coding query to coding worker" do
    assert {:ok, :coding_worker, %{strategy: :rule}} =
             Routers.RuleBased.select_worker(%{query: "please fix this Elixir code"}, %{})
  end

  test "hybrid router supports model and rule fallback" do
    assert {:ok, :coding_worker, %{strategy: :hybrid}} =
             Routers.Hybrid.select_worker(%{query: "hello", model_hint: :coding}, %{})

    assert {:ok, :general_worker, %{strategy: :hybrid}} =
             Routers.Hybrid.select_worker(%{query: "just summarize this text"}, %{})
  end

  test "coordinator submits request and receives orchestrated worker result" do
    assert {:ok,
            %{
              status: :ok,
              worker_kind: :general_worker,
              route: %{strategy: :hybrid},
              agent_id: "coordinator",
              orchestrator_agent_id: "orchestrator",
              worker_agent_id: "worker:general_worker",
              parent_call_id: parent_call_id
            }} = Coordinator.submit(%{query: "summarize current session"})

    assert is_binary(parent_call_id)
  end

  test "coordinator returns degraded result on orchestration failure" do
    assert {:ok, %{status: :degraded, reason: :model_route_not_available}} =
             Coordinator.submit(%{query: "route should fail without model hint"},
               routing_mode: :model
             )
  end

  test "orchestrator dispatch isolates worker failure" do
    assert {:error, :forced_worker_failure} =
             Orchestrator.dispatch(%{query: "fail", force_error: true}, %{})
  end

  test "orchestrator reads and writes memory around dispatch" do
    session_id = "orch_memory_#{System.unique_integer([:positive])}"
    assert {:ok, _} = Prehen.Memory.ensure_session(session_id)
    assert {:ok, _} = Prehen.Memory.put_working_context(session_id, %{topic: "routing"})

    assert {:ok, %{context: worker_context}} =
             Orchestrator.dispatch(%{query: "summarize session", session_id: session_id}, %{})

    assert worker_context.memory_context.stm.working_context.topic == "routing"

    assert {:ok, memory_context} = Prehen.Memory.context(session_id)

    assert Enum.any?(memory_context.stm.conversation_buffer, fn turn ->
             turn.source == "orchestrator"
           end)
  end
end
