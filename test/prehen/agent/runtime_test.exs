defmodule Prehen.Agent.RuntimeTest do
  use ExUnit.Case

  alias Prehen.Agent.Runtime

  test "delegates successful execution to configured backend" do
    Prehen.Test.MockBackend.set_results([
      {:ok, %{status: :ok, answer: "done", steps: 2, trace: [%{event: :finished}]}}
    ])

    assert {:ok, result} =
             Runtime.run("inspect files",
               agent_backend: Prehen.Test.MockBackend,
               max_steps: 5
             )

    assert result.status == :ok
    assert result.answer == "done"
    assert [%{event: :finished}] = result.trace
  end

  test "returns backend failure as runtime failure" do
    Prehen.Test.MockBackend.set_results([
      {:error, %{status: :error, reason: :unknown_provider, trace: [%{event: :failed}]}}
    ])

    assert {:error, result} =
             Runtime.run("bad config",
               agent_backend: Prehen.Test.MockBackend
             )

    assert result.status == :error
    assert result.reason == :unknown_provider
  end

  test "uses session runtime path for jido backend" do
    assert {:ok, result} =
             Runtime.run("hello",
               agent_backend: Prehen.Agent.Backends.JidoAI,
               session_adapter: Prehen.Test.FakeSessionAdapter,
               timeout_ms: 600,
               max_steps: 4
             )

    assert result.status == :ok
    assert result.answer == "answer:hello"
    assert Enum.any?(result.trace, &(&1.type == "ai.request.started"))
    assert Enum.any?(result.trace, &(&1.type == "ai.request.completed"))
  end

  test "runtime can resume a historical session by session_id" do
    opts = [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 600,
      max_steps: 4
    ]

    {:ok, session_pid} = Runtime.start_session(opts)
    assert {:ok, _} = Runtime.prompt(session_pid, "runtime first")
    assert {:ok, _} = Runtime.await_idle(session_pid, timeout: 3_000)
    assert {:ok, status} = Runtime.session_status(session_pid)
    assert :ok = Runtime.stop_session(session_pid)

    {:ok, resumed_pid} = Runtime.resume_session(status.session_id, opts)

    on_exit(fn ->
      if Process.alive?(resumed_pid), do: Runtime.stop_session(resumed_pid)
    end)

    assert {:ok, _} = Runtime.prompt(resumed_pid, "runtime second")
    assert {:ok, result} = Runtime.await_idle(resumed_pid, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    assert Enum.any?(result.trace, fn event ->
             event.type == "ai.session.turn.started" and event.turn_id == 2
           end)
  end
end
