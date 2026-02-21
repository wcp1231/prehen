defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case

  alias Prehen.Client.Surface
  alias Prehen.Conversation.SessionLedger

  defp client_opts(extra) do
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

  test "unified session api supports create/submit/status/stop" do
    assert {:ok, session} = Surface.create_session(client_opts([]))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    assert {:ok, submit} = Surface.submit_message(session.session_pid, "hello unified api")
    assert submit.status == :accepted
    assert submit.session_id == session.session_id
    assert is_binary(submit.request_id)

    assert {:ok, status} = Surface.session_status(session.session_pid)
    assert is_binary(status.workspace_dir)

    assert {:ok, result} = Surface.await_result(session.session_pid, timeout: 3_000)
    assert result.status == :ok

    assert :ok = Surface.stop_session(session.session_pid)
    refute Process.alive?(session.session_pid)
  end

  test "event subscription contract delivers typed envelope events" do
    assert {:ok, session} = Surface.create_session(client_opts([]))

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
    assert {:ok, session} = Surface.create_session(client_opts([]))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Surface.submit_message(session.session_pid, "slow task")
    assert {:error, error} = Surface.await_result(session.session_pid, timeout: 1)
    assert error.status == :error
    assert error.type == :timeout
  end

  test "resume_session keeps session_id stable and preserves correlation fields" do
    opts = client_opts([])
    {:ok, created} = Surface.create_session(opts)

    assert {:ok, _} = Surface.submit_message(created.session_pid, "first surface turn")
    assert {:ok, _} = Surface.await_result(created.session_pid, timeout: 3_000)
    assert :ok = Surface.stop_session(created.session_pid)

    {:ok, resumed} = Surface.resume_session(created.session_id, opts)

    on_exit(fn ->
      if Process.alive?(resumed.session_pid), do: Surface.stop_session(resumed.session_pid)
    end)

    assert resumed.session_id == created.session_id

    assert {:ok, submit} = Surface.submit_message(resumed.session_pid, "second surface turn")
    assert submit.session_id == created.session_id

    assert {:ok, result} = Surface.await_result(resumed.session_pid, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    assert Enum.all?(result.trace, fn event ->
             event.session_id == created.session_id
           end)
  end

  test "resume_session returns unified error when ledger is corrupt" do
    session_id = "surface_corrupt_#{System.unique_integer([:positive])}"
    ledger_file = SessionLedger.session_file(session_id)
    File.mkdir_p!(Path.dirname(ledger_file))
    File.write!(ledger_file, "{\"broken_json\"")

    assert {:error, error} =
             Surface.resume_session(session_id, client_opts([]))

    assert error.status == :error
    assert error.type == :session_resume_failed

    assert match?(
             {:session_recovery_failed, ^session_id, {:ledger_corrupt, %{line: 1}}},
             error.reason
           )
  end

  test "create_session returns unified error on explicit workspace mismatch" do
    {:ok, session} = Surface.create_session(client_opts([]))

    other_workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_surface_workspace_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(other_workspace)

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
      File.rm_rf(other_workspace)
    end)

    assert {:error, error} =
             Surface.create_session(client_opts(workspace: other_workspace))

    assert error.status == :error
    assert error.type == :session_create_failed
    assert match?({:workspace_mismatch, _}, error.reason)
  end
end
