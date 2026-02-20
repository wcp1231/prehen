defmodule Prehen.Workspace.SessionManagerTest do
  use ExUnit.Case

  defp session_opts(extra) do
    base = [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 800,
      max_steps: 4,
      root_dir: ".",
      read_max_bytes: 1024,
      session_status_poll_ms: 20,
      workspace_id: "ws-manager"
    ]

    Keyword.merge(base, extra)
  end

  test "session lifecycle transitions through created/running/idle" do
    {:ok, session} = Prehen.create_session(session_opts(workspace_id: "ws-lifecycle"))

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
    {:ok, session} =
      Prehen.create_session(session_opts(workspace_id: "ws-reclaim", session_idle_ttl_ms: 150))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Prehen.submit_message(session.session_pid, "cleanup me")
    assert {:ok, _} = Prehen.await_result(session.session_pid, timeout: 3_000)

    assert wait_until(fn -> not Process.alive?(session.session_pid) end, 5_000)

    assert {:error, %{type: :session_status_failed, reason: :not_found}} =
             Prehen.session_status(session.session_pid)

    sessions = Prehen.list_sessions(workspace_id: "ws-reclaim")
    refute Enum.any?(sessions, &(&1.pid == session.session_pid))
  end

  test "workspace can enable and disable capability packs" do
    workspace_id = "ws-cap-#{System.unique_integer([:positive])}"
    assert :ok = Prehen.set_workspace_capability_packs(workspace_id, [])

    {:ok, session} =
      Prehen.create_session(session_opts(workspace_id: workspace_id, capability_allowlist: []))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Prehen.stop_session(session.session_pid)
    end)

    assert {:ok, status} = Prehen.session_status(session.session_pid)
    assert status.capability_packs == []
  end

  test "start_session validates capability allowlist and unknown packs" do
    assert {:error, %{type: :session_create_failed, reason: {:capability_not_allowed, :local_fs}}} =
             Prehen.create_session(
               session_opts(
                 workspace_id: "ws-denied",
                 capability_packs: [:local_fs],
                 capability_allowlist: []
               )
             )

    assert {:error,
            %{type: :session_create_failed, reason: {:capability_pack_not_found, :unknown_pack}}} =
             Prehen.create_session(
               session_opts(
                 workspace_id: "ws-unknown",
                 capability_packs: [:unknown_pack],
                 capability_allowlist: [:unknown_pack]
               )
             )
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
