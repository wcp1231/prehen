defmodule Prehen.Integration.PlatformRuntimeTest do
  use ExUnit.Case

  alias Prehen.Agent.Orchestrator
  alias Prehen.Client.Surface
  alias Prehen.Conversation.SessionLedger

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

  test "restart recovery: replay historical ledger and continue dialogue" do
    {:ok, session} = Surface.create_session(opts(workspace_id: "ws-restart-recovery"))
    assert {:ok, _} = Surface.submit_message(session.session_pid, "restart first")
    assert {:ok, _} = Surface.await_result(session.session_pid, timeout: 3_000)
    assert :ok = Surface.stop_session(session.session_pid)

    old_store_pid = Process.whereis(Prehen.Conversation.Store)
    old_stm_pid = Process.whereis(Prehen.Memory.STM)
    Process.exit(old_store_pid, :kill)
    Process.exit(old_stm_pid, :kill)

    assert wait_until(fn ->
             new_store_pid = Process.whereis(Prehen.Conversation.Store)
             new_stm_pid = Process.whereis(Prehen.Memory.STM)

             is_pid(new_store_pid) and is_pid(new_stm_pid) and new_store_pid != old_store_pid and
               new_stm_pid != old_stm_pid
           end)

    {:ok, resumed} =
      Surface.resume_session(session.session_id, opts(workspace_id: "ws-restart-recovery"))

    on_exit(fn ->
      if Process.alive?(resumed.session_pid), do: Surface.stop_session(resumed.session_pid)
    end)

    assert {:ok, _} = Surface.submit_message(resumed.session_pid, "restart second")
    assert {:ok, result} = Surface.await_result(resumed.session_pid, timeout: 3_000)

    assert Enum.any?(result.trace, fn event -> event.type == "ai.session.recovered" end)

    assert Enum.any?(result.trace, fn event ->
             event.type == "ai.session.turn.started" and event.turn_id == 2
           end)

    assert {:ok, context} = Prehen.Memory.context(session.session_id)

    assert Enum.any?(context.stm.conversation_buffer, fn turn -> turn.input == "restart first" end)

    assert Enum.any?(context.stm.conversation_buffer, fn turn ->
             turn.input == "restart second"
           end)
  end

  test "concurrent sessions are isolated by independent session ledgers" do
    session_ids =
      for idx <- 1..4 do
        {:ok, session} = Surface.create_session(opts(workspace_id: "ws-ledger-isolation"))

        try do
          assert {:ok, _} = Surface.submit_message(session.session_pid, "isolation #{idx}")
          assert {:ok, %{status: :ok}} = Surface.await_result(session.session_pid, timeout: 3_000)
          session.session_id
        after
          if Process.alive?(session.session_pid), do: Surface.stop_session(session.session_pid)
        end
      end

    assert length(session_ids) == length(Enum.uniq(session_ids))

    Enum.each(session_ids, fn session_id ->
      assert File.exists?(SessionLedger.session_file(session_id))

      records = Prehen.replay_session(session_id)
      assert records != []
      assert Enum.all?(records, fn record -> record.session_id == session_id end)
    end)
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
