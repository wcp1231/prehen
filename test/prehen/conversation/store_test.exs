defmodule Prehen.Conversation.StoreTest do
  use ExUnit.Case
  import Bitwise

  alias Prehen.Conversation.SessionLedger
  alias Prehen.Conversation.Store
  alias Prehen.Events.Projections.{CLI, Metrics}

  test "writes append-only records and replays by session and kind" do
    session_id = "store_#{System.unique_integer([:positive])}"

    assert {:ok, event_record} = Store.write(session_id, %{type: "ai.request.started", at_ms: 1})
    assert {:ok, message_record} = Store.write(session_id, %{role: :user, content: "hello"})

    assert :ok =
             Store.append(session_id, %{type: "ai.request.completed", at_ms: 2, result: "done"})

    replay_all = Store.replay(session_id)
    assert length(replay_all) == 3
    assert Enum.map(replay_all, & &1.seq) == [1, 2, 3]

    replay_events = Store.replay(session_id, kind: :event)
    assert length(replay_events) == 2
    assert Enum.all?(replay_events, &(&1.kind == :event))

    replay_messages = Store.replay(session_id, kind: :message)
    assert [%{kind: :message}] = replay_messages

    assert event_record.kind == :event
    assert message_record.kind == :message
  end

  test "projection consumers receive canonical records" do
    session_id = "projection_#{System.unique_integer([:positive])}"
    before = Metrics.snapshot()

    assert {:ok, _} = Store.write(session_id, %{type: "ai.request.started"})
    assert {:ok, _} = Store.write(session_id, %{role: :assistant, content: "ok"})

    assert wait_until(fn ->
             events = CLI.events(session_id)
             length(events) >= 2
           end)

    assert wait_until(fn ->
             snapshot = Metrics.snapshot()
             snapshot.total >= before.total + 2
           end)
  end

  test "creates ledger file with minimal permissions" do
    session_id = "perm_#{System.unique_integer([:positive])}"

    assert {:ok, _record} = Store.write(session_id, %{type: "ai.request.started"})

    ledger_file = SessionLedger.session_file(session_id)
    ledger_dir = Path.dirname(ledger_file)

    assert File.exists?(ledger_file)
    assert File.dir?(ledger_dir)
    assert {:ok, file_stat} = File.stat(ledger_file)
    assert {:ok, dir_stat} = File.stat(ledger_dir)
    assert band(file_stat.mode, 0o777) == 0o600
    assert band(dir_stat.mode, 0o777) == 0o700
  end

  test "replay survives conversation store process restart" do
    session_id = "restart_#{System.unique_integer([:positive])}"

    assert {:ok, _record} = Store.write(session_id, %{type: "ai.request.started"})
    assert {:ok, _record} = Store.write(session_id, %{role: :assistant, content: "ok"})

    old_pid = Process.whereis(Store)
    Process.exit(old_pid, :kill)

    assert wait_until(fn ->
             new_pid = Process.whereis(Store)
             is_pid(new_pid) and new_pid != old_pid
           end)

    replay = Store.replay(session_id)
    assert Enum.map(replay, & &1.seq) == [1, 2]
    assert Enum.map(replay, & &1.kind) == [:event, :message]
  end

  test "replay_result hard fails on corrupt ledger" do
    session_id = "corrupt_#{System.unique_integer([:positive])}"

    assert {:ok, _record} = Store.write(session_id, %{type: "ai.request.started"})
    ledger_file = SessionLedger.session_file(session_id)
    File.write!(ledger_file, "{\"bad_json\"", [:append])

    assert {:error, {:ledger_corrupt, %{line: 2}}} = Store.replay_result(session_id)
    assert {:ok, {:ledger_corrupt, %{line: 2}}} = Store.replay_error(session_id)
  end

  defp wait_until(fun, timeout_ms \\ 1_500)

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
