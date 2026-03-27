defmodule Prehen.Gateway.InboxProjectionTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.InboxProjection

  setup do
    InboxProjection.reset()
    :ok
  end

  test "tracks session row, preview, and retained history" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_inbox_1",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hello"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_inbox_1")
    assert row.preview == "hello"
    user_last_event_at = row.last_event_at
    assert is_integer(user_last_event_at)
    assert user_last_event_at >= row.created_at

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hi"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_inbox_1")
    assert row.session_id == "gw_inbox_1"
    assert row.agent_name == "fake_stdio"
    assert row.status == :attached
    assert row.created_at == 1_774_625_000_000
    assert is_integer(row.last_event_at)
    assert row.last_event_at >= user_last_event_at
    assert row.preview == "hi"

    assert [
             %{
               session_id: "gw_inbox_1",
               agent_name: "fake_stdio",
               status: :attached,
               created_at: 1_774_625_000_000,
               last_event_at: last_event_at,
               preview: "hi"
             }
           ] = InboxProjection.list_sessions()

    assert is_integer(last_event_at)
    assert last_event_at == row.last_event_at

    assert {:ok, history} = InboxProjection.fetch_history("gw_inbox_1")

    assert [
             %{
               id: user_id,
               kind: :user_message,
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hello",
               timestamp: user_timestamp
             },
             %{
               id: assistant_id,
               kind: :assistant_message,
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hi",
               timestamp: assistant_timestamp
             }
           ] = history

    assert is_binary(user_id)
    assert is_integer(user_timestamp)
    assert user_timestamp >= 1_774_625_000_000
    assert is_binary(assistant_id)
    assert assistant_id != user_id
    assert is_integer(assistant_timestamp)
    assert assistant_timestamp >= user_timestamp
  end

  test "merges multiple deltas for one assistant message" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_delta_merge",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_delta_merge",
               message_id: "request_merge",
               text: "he"
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_delta_merge",
               message_id: "request_merge",
               text: "llo"
             })

    assert {:ok, history} = InboxProjection.fetch_history("gw_delta_merge")

    assert [
             %{
               id: id,
               kind: :assistant_message,
               session_id: "gw_delta_merge",
               message_id: "request_merge",
               text: "hello",
               timestamp: timestamp
             }
           ] = history

    assert is_binary(id)
    assert is_integer(timestamp)

    assert {:ok, row} = InboxProjection.fetch_session("gw_delta_merge")
    assert row.preview == "hello"
    assert row.last_event_at == timestamp
  end
end
