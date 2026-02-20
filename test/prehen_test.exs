defmodule PrehenTest do
  use ExUnit.Case

  defp session_opts do
    [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 800,
      max_steps: 4,
      root_dir: ".",
      read_max_bytes: 1024,
      session_status_poll_ms: 20
    ]
  end

  test "delegates to runtime and returns structured result" do
    Prehen.Test.MockBackend.set_results([
      {:ok, %{answer: "done", status: :ok, trace: []}}
    ])

    assert {:ok, %{answer: "done", status: :ok}} =
             Prehen.run("say done", agent_backend: Prehen.Test.MockBackend)
  end

  test "public session api keeps prompt/follow_up/await_idle baseline behavior" do
    {:ok, session} = Prehen.create_session(session_opts())

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, %{status: :accepted, kind: :prompt}} =
             Prehen.submit_message(session.session_pid, "first", kind: :prompt)

    assert {:ok, %{status: :accepted, kind: :follow_up}} =
             Prehen.submit_message(session.session_pid, "second", kind: :follow_up)

    assert {:ok, result} = Prehen.await_result(session.session_pid, timeout: 3_000)
    assert result.status == :ok
    assert result.answer == "answer:second"
    assert Enum.count(result.trace, &(&1.type == "ai.request.completed")) == 2
  end

  test "public session api supports steer preemption and stop_session" do
    {:ok, session} = Prehen.create_session(session_opts())
    assert Process.alive?(session.session_pid)

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "slow task")
    Process.sleep(90)
    assert {:ok, _} = Prehen.submit_message(session.session_pid, "urgent", kind: :steering)

    assert {:ok, result} = Prehen.await_result(session.session_pid, timeout: 3_000)
    assert result.status == :ok
    assert result.answer == "answer:urgent"

    assert Enum.any?(result.trace, fn event ->
             event.type == "ai.request.failed" and event.error == {:cancelled, :steering}
           end)

    assert :ok = Prehen.stop_session(session.session_pid)
    refute Process.alive?(session.session_pid)
  end

  test "workspace supports concurrent sessions and status query api" do
    opts = Keyword.put(session_opts(), :workspace_id, "ws-a")

    {:ok, s1} = Prehen.create_session(opts)
    {:ok, s2} = Prehen.create_session(opts)

    on_exit(fn ->
      if Process.alive?(s1.session_pid), do: Prehen.stop_session(s1.session_pid)
      if Process.alive?(s2.session_pid), do: Prehen.stop_session(s2.session_pid)
    end)

    sessions = Prehen.list_sessions(workspace_id: "ws-a")
    assert length(sessions) >= 2
    assert Enum.any?(sessions, &(&1.pid == s1.session_pid))
    assert Enum.any?(sessions, &(&1.pid == s2.session_pid))

    assert {:ok, %{workspace_id: "ws-a", pid: pid, snapshot: %{session_id: session_id}}} =
             Prehen.session_status(s1.session_pid)

    assert pid == s1.session_pid
    assert is_binary(session_id)
  end

  test "public api can replay canonical session records" do
    {:ok, session} = Prehen.create_session(session_opts())

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "replay me")
    assert {:ok, result} = Prehen.await_result(session.session_pid, timeout: 3_000)

    session_id = hd(result.trace).session_id
    records = Prehen.replay_session(session_id)

    assert records != []
    assert Enum.any?(records, &(&1.kind == :event and &1.type == "ai.request.started"))
    assert Enum.any?(records, &(&1.kind == :message and &1.role == :user))
  end

  test "public api exposes resume_session and keeps session continuity" do
    opts = Keyword.put(session_opts(), :workspace_id, "ws-public-resume")
    {:ok, created} = Prehen.create_session(opts)

    assert {:ok, _} = Prehen.submit_message(created.session_pid, "public first")
    assert {:ok, _} = Prehen.await_result(created.session_pid, timeout: 3_000)
    assert :ok = Prehen.stop_session(created.session_pid)

    {:ok, resumed} = Prehen.resume_session(created.session_id, opts)

    on_exit(fn ->
      if Process.alive?(resumed.session_pid), do: Prehen.stop_session(resumed.session_pid)
    end)

    assert resumed.session_id == created.session_id
    assert {:ok, _} = Prehen.submit_message(resumed.session_pid, "public second")
    assert {:ok, result} = Prehen.await_result(resumed.session_pid, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    assert Enum.any?(result.trace, fn event ->
             event.type == "ai.session.turn.started" and event.turn_id == 2
           end)
  end
end
