defmodule Prehen.Agent.SessionTest do
  use ExUnit.Case

  alias Prehen.Agent.Session

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

    assert request_completed.request_id == request_started.request_id
    assert request_completed.run_id == request_started.run_id
    assert request_completed.turn_id == request_started.turn_id
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
end
