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
    assert row.last_event_at == 1_774_625_000_000
    assert row.preview == "hi"

    assert [
             %{
               session_id: "gw_inbox_1",
               agent_name: "fake_stdio",
               status: :attached,
               created_at: 1_774_625_000_000,
               last_event_at: 1_774_625_000_000,
               preview: "hi"
             }
           ] = InboxProjection.list_sessions()

    assert {:ok, history} = InboxProjection.fetch_history("gw_inbox_1")

    assert [
             %{
               kind: :user_message,
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hello"
             },
             %{
               kind: :assistant_message,
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hi"
             }
           ] = history
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
             %{kind: :assistant_message, message_id: "request_merge", text: "hello"}
           ] = history
  end
end
