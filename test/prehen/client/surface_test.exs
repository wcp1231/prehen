defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case

  alias Prehen.Client.Surface

  defp client_opts(extra) do
    base = [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 800,
      max_steps: 4,
      root_dir: ".",
      read_max_bytes: 1024,
      session_status_poll_ms: 20,
      workspace_id: "ws-client"
    ]

    Keyword.merge(base, extra)
  end

  test "unified session api supports create/submit/status/stop" do
    assert {:ok, session} = Surface.create_session(client_opts(workspace_id: "ws-surface"))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    assert {:ok, submit} = Surface.submit_message(session.session_pid, "hello unified api")
    assert submit.status == :accepted
    assert submit.session_id == session.session_id
    assert is_binary(submit.request_id)

    assert {:ok, status} = Surface.session_status(session.session_pid)
    assert status.workspace_id == "ws-surface"

    assert {:ok, result} = Surface.await_result(session.session_pid, timeout: 3_000)
    assert result.status == :ok

    assert :ok = Surface.stop_session(session.session_pid)
    refute Process.alive?(session.session_pid)
  end

  test "event subscription contract delivers typed envelope events" do
    assert {:ok, session} = Surface.create_session(client_opts(workspace_id: "ws-stream"))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    session_id = session.session_id
    assert {:ok, %{session_id: ^session_id}} = Surface.subscribe_events(session.session_id)
    assert {:ok, _} = Surface.submit_message(session.session_pid, "stream me")

    assert_receive {:session_event, event}, 1_000
    assert event.session_id == session_id
    assert is_binary(event.type)
    assert is_integer(event.at_ms)
    assert event.schema_version == 2
  end

  test "await timeout returns unified error shape" do
    assert {:ok, session} = Surface.create_session(client_opts(workspace_id: "ws-timeout"))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Surface.submit_message(session.session_pid, "slow task")
    assert {:error, error} = Surface.await_result(session.session_pid, timeout: 1)
    assert error.status == :error
    assert error.type == :timeout
  end
end
