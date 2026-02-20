defmodule Prehen.Agent.SessionTest do
  use ExUnit.Case

  alias Prehen.Agent.Session
  alias Prehen.Conversation.SessionLedger

  defmodule FailingLTMAdapter do
    @behaviour Prehen.Memory.LTM.Adapter

    @impl true
    def get(_session_id, _query), do: {:error, :ltm_unavailable}

    @impl true
    def put(_session_id, _entry, _meta), do: {:error, :ltm_unavailable}
  end

  defp base_config do
    %{
      model: "openai:gpt-5-mini",
      timeout_ms: 800,
      max_steps: 4,
      root_dir: ".",
      read_max_bytes: 1024,
      session_status_poll_ms: 20,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      retry_policy: Prehen.Agent.Policies.RetryPolicy,
      model_router: Prehen.Agent.Policies.ModelRouter
    }
  end

  test "processes prompt then follow-up in order" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    assert {:ok, _} = Session.prompt(session, "first")
    assert {:ok, _} = Session.follow_up(session, "second")

    assert {:ok, result} = Session.await_idle(session, timeout: 3_000)
    assert result.status == :ok
    assert result.answer == "answer:second"

    event_types = Enum.map(result.trace, & &1.type)
    assert Enum.count(event_types, &(&1 == "ai.session.turn.started")) == 2
    assert Enum.count(event_types, &(&1 == "ai.request.completed")) == 2
    assert "ai.session.queue.drained" in event_types
  end

  test "steering cancels current turn and prioritizes queued steering prompt" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    assert {:ok, _} = Session.prompt(session, "slow task")
    Process.sleep(90)
    assert {:ok, _} = Session.steer(session, "urgent")

    assert {:ok, result} = Session.await_idle(session, timeout: 3_000)
    assert result.status == :ok
    assert result.answer == "answer:urgent"

    failed =
      Enum.find(result.trace, fn event ->
        event.type == "ai.request.failed" and event.request_id != nil
      end)

    assert failed
    assert failed.error == {:cancelled, :steering}

    skipped =
      Enum.find(result.trace, fn event ->
        event.type == "ai.tool.result" and match?({:error, %{type: "skipped"}}, event.result)
      end)

    assert skipped
  end

  test "emits correlation fields for lifecycle events" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    assert {:ok, _} = Session.prompt(session, "hello")
    assert {:ok, result} = Session.await_idle(session, timeout: 3_000)

    request_started = Enum.find(result.trace, &(&1.type == "ai.request.started"))
    request_completed = Enum.find(result.trace, &(&1.type == "ai.request.completed"))

    assert is_binary(request_started.session_id)
    assert is_binary(request_started.request_id)
    assert is_binary(request_started.run_id)
    assert is_integer(request_started.turn_id)
    assert is_integer(request_started.at_ms)
    assert request_started.source == "prehen.session"
    assert request_started.schema_version == 2

    assert request_completed.request_id == request_started.request_id
    assert request_completed.run_id == request_started.run_id
    assert request_completed.turn_id == request_started.turn_id
    assert request_completed.schema_version == 2
  end

  test "handles concurrent message injections and keeps queue draining contract" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    tasks = [
      Task.async(fn -> Session.prompt(session, "p1") end),
      Task.async(fn -> Session.follow_up(session, "p2") end),
      Task.async(fn -> Session.follow_up(session, "p3") end)
    ]

    Enum.each(tasks, fn task ->
      assert {:ok, _} = Task.await(task, 1_000)
    end)

    assert {:ok, result} = Session.await_idle(session, timeout: 4_000)
    assert result.status == :ok
    assert result.answer == "answer:p3"

    completed = Enum.filter(result.trace, &(&1.type == "ai.request.completed"))
    assert length(completed) == 3
    assert List.last(result.trace).type == "ai.session.queue.drained"
  end

  test "persists turn context into session stm memory" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    assert {:ok, _} = Session.prompt(session, "memory hello")
    assert {:ok, _} = Session.await_idle(session, timeout: 3_000)

    %{session_id: session_id} = Session.snapshot(session)
    assert {:ok, context} = Prehen.Memory.context(session_id)

    assert Enum.any?(context.stm.conversation_buffer, fn turn ->
             turn.source == "session" and turn.input == "memory hello" and turn.status == :ok
           end)

    assert context.stm.token_budget.used > 0
  end

  test "writes ai.session.turn.summary with normalized fields" do
    {:ok, session} = Session.start(base_config())
    on_exit(fn -> Session.stop(session) end)

    assert {:ok, _} = Session.prompt(session, "summary please")
    assert {:ok, _} = Session.await_idle(session, timeout: 3_000)

    %{session_id: session_id} = Session.snapshot(session)

    summary =
      session_id
      |> Prehen.Conversation.Store.replay(kind: :event)
      |> Enum.find(fn record -> record.type == "ai.session.turn.summary" end)

    assert summary.turn_id == 1
    assert summary.input == "summary please"
    assert summary.answer == "answer:summary please"
    assert summary.status == :ok
    assert is_list(summary.tool_calls)
    assert is_map(summary.working_context)
    assert Map.get(summary.working_context, "last_turn_status") == :ok
  end

  test "resume rebuilds stm and continues turn sequence" do
    config = base_config()
    {:ok, session} = Session.start(config)
    assert {:ok, _} = Session.prompt(session, "first turn")
    assert {:ok, _} = Session.await_idle(session, timeout: 3_000)

    %{session_id: session_id} = Session.snapshot(session)
    Session.stop(session)

    resume_config =
      config
      |> Map.put(:session_id, session_id)
      |> Map.put(:resume, true)

    {:ok, resumed} = Session.start(resume_config)
    on_exit(fn -> Session.stop(resumed) end)

    assert {:ok, _} = Session.prompt(resumed, "second turn")
    assert {:ok, result} = Session.await_idle(resumed, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    started_turn_ids =
      result.trace
      |> Enum.filter(&(&1.type == "ai.session.turn.started"))
      |> Enum.map(& &1.turn_id)

    assert Enum.max(started_turn_ids) == 2

    assert {:ok, context} = Prehen.Memory.context(session_id)

    assert Enum.any?(context.stm.conversation_buffer, fn turn ->
             turn.input == "first turn"
           end)

    assert Enum.any?(context.stm.conversation_buffer, fn turn ->
             turn.input == "second turn"
           end)
  end

  test "resume hard fails on corrupt ledger" do
    session_id = "broken_#{System.unique_integer([:positive])}"
    ledger_file = SessionLedger.session_file(session_id)
    File.mkdir_p!(Path.dirname(ledger_file))
    File.write!(ledger_file, "{\"broken_json\"")

    resume_config =
      base_config()
      |> Map.put(:session_id, session_id)
      |> Map.put(:resume, true)

    assert {:error, {:session_recovery_failed, ^session_id, {:ledger_corrupt, %{line: 1}}}} =
             Session.start(resume_config)
  end

  test "resume keeps working when ltm adapter is unavailable" do
    config =
      base_config()
      |> Map.put(:ltm_adapter, FailingLTMAdapter)

    {:ok, session} = Session.start(config)
    assert {:ok, _} = Session.prompt(session, "ltm first")
    assert {:ok, _} = Session.await_idle(session, timeout: 3_000)
    %{session_id: session_id} = Session.snapshot(session)
    Session.stop(session)

    resume_config =
      config
      |> Map.put(:session_id, session_id)
      |> Map.put(:resume, true)

    {:ok, resumed} = Session.start(resume_config)
    on_exit(fn -> Session.stop(resumed) end)

    assert {:ok, _} = Session.prompt(resumed, "ltm second")
    assert {:ok, %{status: :ok}} = Session.await_idle(resumed, timeout: 3_000)

    assert {:ok, context} = Prehen.Memory.context(session_id, ltm_adapter: FailingLTMAdapter)
    assert context.source == :stm_ltm_degraded
    assert Enum.any?(context.stm.conversation_buffer, fn turn -> turn.input == "ltm second" end)
  end
end
