defmodule Prehen.Workspace.SessionManagerTest do
  use ExUnit.Case

  alias Prehen.Conversation.SessionLedger

  defp session_opts(extra) do
    base = [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 800,
      max_steps: 4,
      read_max_bytes: 1024,
      session_status_poll_ms: 20
    ]

    Keyword.merge(base, extra)
  end

  test "session lifecycle transitions through created/running/idle" do
    {:ok, session} = Prehen.create_session(session_opts([]))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, %{lifecycle: lifecycle}} = Prehen.session_status(session.session_pid)
    assert lifecycle in [:created, :idle]

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "do work")

    assert wait_until(fn ->
             match?({:ok, %{lifecycle: :running}}, Prehen.session_status(session.session_pid))
           end)

    assert {:ok, _} = Prehen.await_result(session.session_pid, timeout: 3_000)

    assert wait_until(fn ->
             match?({:ok, %{lifecycle: :idle}}, Prehen.session_status(session.session_pid))
           end)
  end

  test "idle sessions are reclaimed after ttl" do
    {:ok, session} = Prehen.create_session(session_opts(session_idle_ttl_ms: 150))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "cleanup me")
    assert {:ok, _} = Prehen.await_result(session.session_pid, timeout: 3_000)

    assert wait_until(fn -> not Process.alive?(session.session_pid) end, 5_000)

    assert {:error, %{type: :session_status_failed, reason: :not_found}} =
             Prehen.session_status(session.session_pid)

    sessions = Prehen.list_sessions()
    refute Enum.any?(sessions, &(&1.pid == session.session_pid))
  end

  test "workspace can enable and disable capability packs" do
    assert :ok = Prehen.set_capability_packs([])

    {:ok, session} = Prehen.create_session(session_opts(capability_allowlist: []))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, status} = Prehen.session_status(session.session_pid)
    assert status.capability_packs == []
  end

  test "can resume historical session in the same workspace" do
    opts = session_opts([])
    {:ok, session} = Prehen.create_session(opts)
    assert {:ok, _} = Prehen.submit_message(session.session_pid, "first resume turn")
    assert {:ok, _} = Prehen.await_result(session.session_pid, timeout: 3_000)

    session_id = session.session_id
    assert :ok = Prehen.stop_session(session.session_pid)

    {:ok, resumed} = Prehen.resume_session(session_id, opts)

    on_exit(fn ->
      if Process.alive?(resumed.session_pid), do: Prehen.stop_session(resumed.session_pid)
    end)

    assert resumed.session_id == session_id
    assert {:ok, _} = Prehen.submit_message(resumed.session_pid, "second resume turn")
    assert {:ok, result} = Prehen.await_result(resumed.session_pid, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    assert Enum.any?(result.trace, fn event ->
             event.type == "ai.session.turn.started" and event.turn_id == 2
           end)
  end

  test "idle reclaim releases process but keeps ledger file for later recovery" do
    opts = session_opts(session_idle_ttl_ms: 150)
    {:ok, session} = Prehen.create_session(opts)

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "persist me")
    assert {:ok, _} = Prehen.await_result(session.session_pid, timeout: 3_000)

    ledger_file = SessionLedger.session_file(session.session_id)

    assert wait_until(fn -> not Process.alive?(session.session_pid) end, 5_000)
    assert File.exists?(ledger_file)

    {:ok, resumed} = Prehen.resume_session(session.session_id, opts)

    on_exit(fn ->
      if Process.alive?(resumed.session_pid), do: Prehen.stop_session(resumed.session_pid)
    end)

    assert resumed.session_id == session.session_id
  end

  test "start_session validates capability allowlist and unknown packs" do
    assert {:error, %{type: :session_create_failed, reason: {:capability_not_allowed, :local_fs}}} =
             Prehen.create_session(
               session_opts(
                 capability_packs: [:local_fs],
                 capability_allowlist: []
               )
             )

    assert {:error,
            %{type: :session_create_failed, reason: {:capability_pack_not_found, :unknown_pack}}} =
             Prehen.create_session(
               session_opts(
                 capability_packs: [:unknown_pack],
                 capability_allowlist: [:unknown_pack]
               )
             )
  end

  test "explicit workspace override mismatch is rejected without impacting existing sessions" do
    {:ok, session} = Prehen.create_session(session_opts([]))

    other_workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_workspace_mismatch_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(other_workspace)

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
      File.rm_rf(other_workspace)
    end)

    assert {:error, %{type: :session_create_failed, reason: {:workspace_mismatch, _details}}} =
             Prehen.create_session(session_opts(workspace: other_workspace))

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "still alive")
    assert {:ok, %{status: :ok}} = Prehen.await_result(session.session_pid, timeout: 3_000)
  end

  defp wait_until(fun, timeout_ms \\ 2_000)

  defp wait_until(fun, timeout_ms) when timeout_ms <= 0, do: fun.()

  defp wait_until(fun, timeout_ms) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, timeout_ms - 25)
    end
  end
end
