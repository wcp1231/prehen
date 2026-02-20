defmodule Prehen.Integration.PlatformRuntimeTest do
  use ExUnit.Case

  alias Prehen.Agent.Orchestrator
  alias Prehen.Client.Surface

  defp opts(extra) do
    base = [
      agent_backend: Prehen.Agent.Backends.JidoAI,
      session_adapter: Prehen.Test.FakeSessionAdapter,
      timeout_ms: 800,
      max_steps: 4,
      root_dir: ".",
      read_max_bytes: 1024,
      session_status_poll_ms: 20
    ]

    Keyword.merge(base, extra)
  end

  test "integration: session + orchestration + memory + event-store" do
    {:ok, session} = Surface.create_session(opts(workspace_id: "ws-integration"))

    on_exit(fn ->
      if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
    end)

    assert {:ok, _} = Surface.subscribe_events(session.session_id)
    assert {:ok, _} = Surface.submit_message(session.session_pid, "integrate all subsystems")
    assert {:ok, result} = Surface.await_result(session.session_pid, timeout: 3_000)
    assert result.status == :ok

    assert_receive {:session_event, event}, 1_000
    assert event.session_id == session.session_id
    assert is_binary(event.type)
    assert event.schema_version == 2

    assert {:ok, memory_before} = Prehen.Memory.context(session.session_id)

    assert Enum.any?(memory_before.stm.conversation_buffer, fn turn ->
             turn.source == "session"
           end)

    assert {:ok, %{status: :ok}} =
             Orchestrator.dispatch(
               %{query: "summarize this session", session_id: session.session_id},
               %{}
             )

    assert {:ok, memory_after} = Prehen.Memory.context(session.session_id)

    assert Enum.any?(memory_after.stm.conversation_buffer, fn turn ->
             turn.source == "orchestrator"
           end)

    records = Prehen.replay_session(session.session_id)
    assert Enum.any?(records, &(&1.kind == :event and &1.type == "ai.request.completed"))
    assert Enum.any?(records, &(&1.kind == :message and &1.role == :assistant))
  end

  test "regression load: concurrent sessions keep behavior stable" do
    tasks =
      for idx <- 1..8 do
        Task.async(fn ->
          {:ok, session} =
            Surface.create_session(opts(workspace_id: "ws-load", session_idle_ttl_ms: 5_000))

          try do
            assert {:ok, _} = Surface.submit_message(session.session_pid, "load #{idx}")

            assert {:ok, %{status: :ok}} =
                     Surface.await_result(session.session_pid, timeout: 3_000)

            :ok
          after
            if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
          end
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 8_000))
    assert Enum.all?(results, &(&1 == :ok))
  end
end
