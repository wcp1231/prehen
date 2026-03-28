defmodule PrehenWeb.EventSerializerTest do
  use ExUnit.Case, async: true

  alias PrehenWeb.EventSerializer

  describe "serialize/1" do
    test "converts atom values to strings" do
      assert EventSerializer.serialize(%{chunk_type: :content}) ==
               %{"chunk_type" => "content"}
    end

    test "preserves boolean and nil" do
      assert EventSerializer.serialize(%{active: true, partial: false, data: nil}) ==
               %{"active" => true, "partial" => false, "data" => nil}
    end

    test "preserves strings and numbers" do
      assert EventSerializer.serialize(%{type: "ai.llm.delta", seq: 5, at_ms: 1_000}) ==
               %{"type" => "ai.llm.delta", "seq" => 5, "at_ms" => 1_000}
    end

    test "converts {:ok, value} tuple" do
      result = EventSerializer.serialize(%{result: {:ok, "file content"}})
      assert result == %{"result" => %{"status" => "ok", "value" => "file content"}}
    end

    test "converts {:error, reason} tuple" do
      result = EventSerializer.serialize(%{result: {:error, :timeout}})
      assert result == %{"result" => %{"status" => "error", "reason" => ":timeout"}}
    end

    test "drops pid values" do
      result = EventSerializer.serialize(%{session_id: "abc", session_pid: self()})
      assert result == %{"session_id" => "abc"}
      refute Map.has_key?(result, "session_pid")
    end

    test "drops reference values" do
      ref = make_ref()
      result = EventSerializer.serialize(%{name: "test", ref: ref})
      assert result == %{"name" => "test"}
    end

    test "recursively converts nested maps" do
      event = %{
        type: "ai.tool.result",
        payload: %{status: :completed, result: {:ok, "data"}}
      }

      result = EventSerializer.serialize(event)

      assert result == %{
               "type" => "ai.tool.result",
               "payload" => %{
                 "status" => "completed",
                 "result" => %{"status" => "ok", "value" => "data"}
               }
             }
    end

    test "converts lists recursively" do
      event = %{
        tool_calls: [
          %{name: "read", call_id: "c1", status: :completed},
          %{name: "ls", call_id: "c2", status: :running}
        ]
      }

      result = EventSerializer.serialize(event)

      assert result == %{
               "tool_calls" => [
                 %{"name" => "read", "call_id" => "c1", "status" => "completed"},
                 %{"name" => "ls", "call_id" => "c2", "status" => "running"}
               ]
             }
    end

    test "drops pids inside lists" do
      result = EventSerializer.serialize(%{items: [1, self(), 3]})
      assert result == %{"items" => [1, 3]}
    end

    test "converts generic tuples to lists" do
      result = EventSerializer.serialize(%{coords: {1, 2, 3}})
      assert result == %{"coords" => [1, 2, 3]}
    end

    test "converts atom keys to string keys" do
      result = EventSerializer.serialize(%{:session_id => "s1", "already_string" => "v"})
      assert result == %{"session_id" => "s1", "already_string" => "v"}
    end

    # -- normalize_error/1 tests (via ai.request.failed events) --

    test "normalizes structured map error with :code key" do
      event = %{
        type: "ai.request.failed",
        error: %{
          code: :llm_stream_exception,
          error_type: :rate_limit,
          reason: "429 Too Many Requests",
          model: "gpt-4"
        }
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "llm_stream_exception"
      assert error["message"] == "429 Too Many Requests"
      assert error["details"]["error_type"] == "rate_limit"
      assert error["details"]["model"] == "gpt-4"
    end

    test "normalizes {:model_fallback_exhausted, %{...}} tuple" do
      event = %{
        type: "ai.request.failed",
        error:
          {:model_fallback_exhausted,
           %{
             reason: "all models failed",
             model_error: %{reason: "Rate limit exceeded (429)"}
           }}
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "model_fallback_exhausted"
      assert error["message"] == "Rate limit exceeded (429)"
      assert is_map(error["details"])
    end

    test "normalizes {:await_crash, reason} tuple" do
      event = %{
        type: "ai.request.failed",
        error: {:await_crash, :noproc}
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "await_crash"
      assert error["message"] == "Session process crashed"
      assert error["details"]["reason"] == ":noproc"
    end

    test "normalizes {:cancelled, :steering} tuple" do
      event = %{
        type: "ai.request.failed",
        error: {:cancelled, :steering}
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "cancelled"
      assert error["message"] == "Request cancelled by user"
      refute Map.has_key?(error, "details")
    end

    test "normalizes :timeout atom error" do
      event = %{
        type: "ai.request.failed",
        error: :timeout
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "timeout"
      assert error["message"] == "Request timed out"
    end

    test "normalizes unknown error with fallback" do
      event = %{
        type: "ai.request.failed",
        error: ["something", "unexpected"]
      }

      result = EventSerializer.serialize(event)
      error = result["error"]

      assert error["code"] == "unknown"
      assert is_binary(error["message"])
    end

    test "does not normalize error field on non-failed events" do
      event = %{
        type: "ai.tool.result",
        error: {:await_crash, :noproc}
      }

      result = EventSerializer.serialize(event)
      # Generic tuple conversion: should become a list, not structured error
      assert result["error"] == ["await_crash", "noproc"]
    end

    test "handles full event envelope" do
      event = %{
        type: "ai.llm.delta",
        call_id: "call_1",
        delta: "Hello",
        chunk_type: :content,
        seq: 3,
        session_id: "session_42",
        at_ms: 1_708_915_200_000,
        schema_version: 2,
        source: "prehen.session"
      }

      result = EventSerializer.serialize(event)

      assert result["type"] == "ai.llm.delta"
      assert result["delta"] == "Hello"
      assert result["chunk_type"] == "content"
      assert result["seq"] == 3
      assert result["session_id"] == "session_42"
      assert result["at_ms"] == 1_708_915_200_000
    end

    test "serializes the gateway envelope without runtime-specific fields" do
      event =
        Prehen.Agents.Envelope.build("session.output.delta", %{
          gateway_session_id: "gw_1",
          agent_session_id: "agent_gw_1",
          agent: "fake_stdio",
          seq: 1,
          payload: %{"text" => "hel"}
        })

      result = EventSerializer.serialize(event)

      assert %{"type" => "session.output.delta", "gateway_session_id" => "gw_1"} = result
      refute Map.has_key?(result, "node")
      refute Map.has_key?(result, "timestamp")
    end

    test "preserves inbox browser event fields" do
      event = %{
        type: "session.output.delta",
        gateway_session_id: "gw_browser",
        agent_session_id: "agent_gw_browser",
        agent: "fake_stdio",
        node: "nonode@nohost",
        timestamp: 1_708_915_200_000,
        payload: %{
          "text" => "hello",
          "message_id" => "msg_123"
        }
      }

      result = EventSerializer.serialize(event)

      assert result["type"] == "session.output.delta"
      assert result["gateway_session_id"] == "gw_browser"
      assert result["agent_session_id"] == "agent_gw_browser"
      assert result["payload"]["text"] == "hello"
      assert result["payload"]["message_id"] == "msg_123"
    end

    test "preserves nested payload metadata fields while dropping top-level gateway runtime fields" do
      event = %{
        type: "session.output.delta",
        gateway_session_id: "gw_1",
        agent_session_id: "agent_gw_1",
        agent: "fake_stdio",
        node: "nonode@nohost",
        timestamp: 1_708_915_200_000,
        seq: 1,
        payload: %{"node" => "inner-node", "timestamp" => 123, "text" => "hel"},
        metadata: %{"node" => "meta-node", "timestamp" => 456}
      }

      result = EventSerializer.serialize(event)

      refute Map.has_key?(result, "node")
      refute Map.has_key?(result, "timestamp")
      assert result["payload"]["node"] == "inner-node"
      assert result["payload"]["timestamp"] == 123
      assert result["metadata"]["node"] == "meta-node"
      assert result["metadata"]["timestamp"] == 456
    end
  end
end
