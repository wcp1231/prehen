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
  end
end
