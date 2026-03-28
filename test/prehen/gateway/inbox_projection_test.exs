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
    assert row.status == :running
    assert row.created_at == 1_774_625_000_000
    assert is_integer(row.last_event_at)
    assert row.last_event_at >= user_last_event_at
    assert row.preview == "hi"

    assert [
             %{
               session_id: "gw_inbox_1",
               agent_name: "fake_stdio",
               status: :running,
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

  test "merges assistant deltas by message_id even when later entries exist" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_interleaved",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_interleaved",
               message_id: "assistant_1",
               text: "he"
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_interleaved",
               message_id: "request_2",
               text: "follow up"
             })

    assert {:ok, row_after_user} = InboxProjection.fetch_session("gw_interleaved")
    assert row_after_user.preview == "follow up"
    user_last_event_at = row_after_user.last_event_at

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_interleaved",
               message_id: "assistant_1",
               text: "llo"
             })

    assert {:ok, history} = InboxProjection.fetch_history("gw_interleaved")

    assert [
             %{
               kind: :user_message,
               session_id: "gw_interleaved",
               message_id: "request_2",
               text: "follow up"
             },
             %{
               kind: :assistant_message,
               session_id: "gw_interleaved",
               message_id: "assistant_1",
               text: "hello"
             }
           ] = Enum.map(history, &Map.take(&1, [:kind, :session_id, :message_id, :text]))

    assert {:ok, row} = InboxProjection.fetch_session("gw_interleaved")
    assert row.preview == "hello"
    assert row.last_event_at > user_last_event_at
  end

  test "duplicate session_started is a no-op that preserves row and history" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_duplicate",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_duplicate",
               message_id: "request_duplicate",
               text: "hello"
             })

    assert {:ok, original_row} = InboxProjection.fetch_session("gw_duplicate")
    assert {:ok, original_history} = InboxProjection.fetch_history("gw_duplicate")

    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_duplicate",
               agent_name: "other_agent",
               created_at: 1_999_999_999_999
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_duplicate")
    assert {:ok, history} = InboxProjection.fetch_history("gw_duplicate")

    assert row == original_row
    assert history == original_history
    assert is_integer(row.last_event_at)

    assert [
             %{
               session_id: "gw_duplicate",
               agent_name: "fake_stdio",
               status: :running,
               created_at: 1_774_625_000_000,
               last_event_at: last_event_at,
               preview: "hello"
             }
           ] = InboxProjection.list_sessions()

    assert last_event_at == row.last_event_at
  end

  test "keeps terminal session history readable after stop" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_terminal",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_terminal",
               message_id: "request_terminal",
               text: "hello"
             })

    assert :ok = InboxProjection.session_stopped(%{session_id: "gw_terminal"})

    assert {:ok, row} = InboxProjection.fetch_session("gw_terminal")
    assert row.status == :stopped

    assert {:ok, history} = InboxProjection.fetch_history("gw_terminal")
    assert Enum.any?(history, &(&1.kind == :user_message))
  end

  test "transitions from attached to running to idle for one request" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_status",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_status",
               message_id: "request_status",
               text: "hello"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_status")
    assert row.status == :running

    assert :ok =
             InboxProjection.agent_completed(%{
               session_id: "gw_status",
               message_id: "request_status"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_status")
    assert row.status == :idle
  end

  test "rejects unknown-session events without creating orphaned history" do
    assert {:error, :not_found} =
             InboxProjection.user_message(%{
               session_id: "gw_missing",
               message_id: "request_missing",
               text: "hello"
             })

    assert {:error, :not_found} =
             InboxProjection.agent_delta(%{
               session_id: "gw_missing",
               message_id: "request_missing",
               text: "hi"
             })

    assert {:error, :not_found} = InboxProjection.fetch_session("gw_missing")
    assert {:error, :not_found} = InboxProjection.fetch_history("gw_missing")
    assert [] = InboxProjection.list_sessions()
  end

  test "malformed attrs return invalid_attrs and preserve retained state" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_retained",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_retained",
               message_id: "request_retained",
               text: "hello"
             })

    assert {:ok, original_row} = InboxProjection.fetch_session("gw_retained")
    assert {:ok, original_history} = InboxProjection.fetch_history("gw_retained")

    assert {:error, :invalid_attrs} = InboxProjection.session_started(%{agent_name: "broken"})

    assert {:error, :invalid_attrs} =
             InboxProjection.user_message(%{"session_id" => "gw_retained"})

    assert {:error, :invalid_attrs} =
             InboxProjection.agent_delta(%{
               session_id: "gw_retained",
               text: "hi"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_retained")
    assert {:ok, history} = InboxProjection.fetch_history("gw_retained")

    assert row == original_row
    assert history == original_history
  end

  test "malformed optional fields return invalid_attrs and preserve retained state" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_optional",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_optional",
               message_id: "request_optional",
               text: "hello"
             })

    assert {:ok, original_row} = InboxProjection.fetch_session("gw_optional")
    assert {:ok, original_history} = InboxProjection.fetch_history("gw_optional")

    assert {:error, :invalid_attrs} =
             InboxProjection.session_started(%{
               session_id: "gw_optional_2",
               created_at: "not-an-integer"
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.user_message(%{
               session_id: "gw_optional",
               message_id: "request_optional_2",
               text: 123
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.agent_delta(%{
               session_id: "gw_optional",
               message_id: "assistant_optional",
               text: 123
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_optional")
    assert {:ok, history} = InboxProjection.fetch_history("gw_optional")

    assert row == original_row
    assert history == original_history
  end

  test "rejects empty ids and malformed agent_name without disturbing retained state" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_ids",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_ids",
               message_id: "request_ids",
               text: "hello"
             })

    assert {:ok, original_row} = InboxProjection.fetch_session("gw_ids")
    assert {:ok, original_history} = InboxProjection.fetch_history("gw_ids")

    assert {:error, :invalid_attrs} =
             InboxProjection.session_started(%{
               session_id: "",
               agent_name: "fake_stdio"
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.session_started(%{
               session_id: "gw_bad_agent",
               agent_name: 123
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.user_message(%{
               session_id: "",
               message_id: "request_bad",
               text: "hello"
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.user_message(%{
               session_id: "gw_ids",
               message_id: "",
               text: "hello"
             })

    assert {:error, :invalid_attrs} =
             InboxProjection.agent_delta(%{
               session_id: "gw_ids",
               message_id: "",
               text: "hello"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_ids")
    assert {:ok, history} = InboxProjection.fetch_history("gw_ids")

    assert row == original_row
    assert history == original_history
  end
end
