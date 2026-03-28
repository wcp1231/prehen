defmodule Prehen.Integration.PlatformRuntimeTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection
  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  setup do
    InboxProjection.reset()
    registry_pid = Process.whereis(Registry)
    original = :sys.get_state(registry_pid)

    fake_profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    :sys.replace_state(registry_pid, fn _state ->
      %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _state -> original end)
    end)

    :ok
  end

  test "control plane HTTP endpoints route through gateway sessions" do
    conn = build_conn()

    conn = post(conn, "/sessions", %{"agent" => "fake_stdio"})
    assert created = json_response(conn, 201)
    assert %{"session_id" => session_id, "agent" => "fake_stdio"} = created

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{"text" => "hello from http"})
    assert submitted = json_response(conn, 202)

    assert submitted["status"] == "accepted"
    assert submitted["session_id"] == session_id
    assert is_binary(submitted["request_id"])

    conn = get(build_conn(), "/agents")
    assert agents = json_response(conn, 200)

    assert Enum.any?(agents["agents"], fn agent ->
             agent["agent"] == "fake_stdio"
           end)
  end

  test "GET /sessions/:id returns JSON-safe gateway status without worker pid" do
    conn = post(build_conn(), "/sessions", %{"agent" => "fake_stdio"})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)

    assert session["session_id"] == session_id
    assert session["status"] == "attached"
    refute Map.has_key?(session, "worker_pid")
  end

  test "POST /sessions/:id/messages returns 400 when message text is missing" do
    conn = post(build_conn(), "/sessions", %{"agent" => "fake_stdio"})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{})
    assert %{"error" => %{"type" => "bad_request"}} = json_response(conn, 400)
  end

  test "DELETE /sessions/:id returns 404 for unknown session" do
    conn = delete(build_conn(), "/sessions/missing_session")
    assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
  end

  test "records gateway lifecycle events for a session run" do
    assert {:ok, %{session_id: gateway_session_id}} =
             Prehen.Client.Surface.create_session(agent: "fake_stdio")

    on_exit(fn -> Surface.stop_session(gateway_session_id) end)

    assert {:ok, _submit} =
             Prehen.Client.Surface.submit_message(gateway_session_id, "hello trace")

    Process.sleep(100)

    assert {:ok, events} = Prehen.Trace.for_session(gateway_session_id)
    assert Enum.any?(events, &(&1.type == "agent.started"))
  end

  test "projects live status transitions and retains history after stop" do
    assert {:ok, %{session_id: session_id}} = Surface.create_session(agent: "fake_stdio")

    assert {:ok, row} = InboxProjection.fetch_session(session_id)
    assert row.status == :attached

    assert {:ok, %{request_id: request_id}} = Surface.submit_message(session_id, "hello inbox")

    assert {:ok, row} =
             wait_until(fn ->
               case InboxProjection.fetch_session(session_id) do
                 {:ok, %{status: :idle} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    assert row.preview == "hi"

    assert :ok = Surface.stop_session(session_id)

    assert {:ok, row} =
             wait_until(fn ->
               case InboxProjection.fetch_session(session_id) do
                 {:ok, %{status: :stopped} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    assert row.status == :stopped

    assert {:ok, history} = InboxProjection.fetch_history(session_id)

    assert Enum.map(history, &Map.take(&1, [:kind, :message_id, :text])) == [
             %{kind: :user_message, message_id: request_id, text: "hello inbox"},
             %{kind: :assistant_message, message_id: request_id, text: "hi"}
           ]
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      :retry ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: {:error, :timeout}
end
