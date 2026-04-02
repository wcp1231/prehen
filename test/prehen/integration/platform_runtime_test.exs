defmodule Prehen.Integration.PlatformRuntimeTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection
  alias Prehen.TestSupport.PiAgentFixture

  @endpoint PrehenWeb.Endpoint

  setup do
    InboxProjection.reset()

    original =
      PiAgentFixture.replace_registry!(
        PiAgentFixture.registry_state([coder_profile()], [coder_implementation()])
      )

    workspace = PiAgentFixture.workspace!("platform_runtime")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "control plane HTTP endpoints route through gateway sessions", %{workspace: workspace} do
    conn =
      post(build_conn(), "/sessions", %{
        "agent" => "coder",
        "provider" => "anthropic",
        "model" => "claude-sonnet",
        "workspace" => workspace
      })

    assert created = json_response(conn, 201)
    assert %{"session_id" => session_id, "agent" => "coder"} = created

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)
    assert session["agent_name"] == "coder"
    assert session["provider"] == "anthropic"
    assert session["model"] == "claude-sonnet"

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{"text" => "hello from http"})
    assert submitted = json_response(conn, 202)

    assert submitted["status"] == "accepted"
    assert submitted["session_id"] == session_id
    assert is_binary(submitted["request_id"])

    conn = get(build_conn(), "/agents")
    assert agents = json_response(conn, 200)

    assert agents["agents"] == [
             %{
               "agent" => "coder",
               "default" => true,
               "description" => "General coding profile",
               "name" => "Coder"
             }
           ]
  end

  test "POST /sessions returns a structured error for an unknown profile name" do
    conn = post(build_conn(), "/sessions", %{"agent" => "missing_profile"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":agent_profile_not_found"
    assert message =~ "missing_profile"
  end

  test "POST /sessions returns a classified error for a misconfigured implementation" do
    set_registry([coder_profile()], [])

    conn = post(build_conn(), "/sessions", %{"agent" => "coder"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":agent_implementation_not_found"
    assert message =~ "coder_impl"
  end

  test "GET /sessions/:id returns JSON-safe gateway status without worker pid", %{
    workspace: workspace
  } do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder", "workspace" => workspace})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)

    assert session["session_id"] == session_id
    assert session["status"] == "attached"
    refute Map.has_key?(session, "worker_pid")
  end

  test "GET /sessions/:id omits worker_pid after retained terminal stop", %{workspace: workspace} do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder", "workspace" => workspace})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    assert :ok = Surface.stop_session(session_id)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)

    assert session["session_id"] == session_id
    assert session["status"] == "stopped"
    refute Map.has_key?(session, "worker_pid")
    assert {:error, :not_found} = Prehen.Gateway.SessionRegistry.fetch_worker(session_id)
  end

  test "POST /sessions/:id/messages returns 400 when message text is missing", %{
    workspace: workspace
  } do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder", "workspace" => workspace})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{})
    assert %{"error" => %{"type" => "bad_request"}} = json_response(conn, 400)
  end

  test "DELETE /sessions/:id returns 404 for unknown session" do
    conn = delete(build_conn(), "/sessions/missing_session")
    assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
  end

  test "records gateway lifecycle events for a session run", %{workspace: workspace} do
    assert {:ok, %{session_id: gateway_session_id}} =
             Surface.create_session(agent: "coder", workspace: workspace)

    on_exit(fn -> Surface.stop_session(gateway_session_id) end)

    assert {:ok, _submit} = Surface.submit_message(gateway_session_id, "hello trace")

    Process.sleep(100)

    assert {:ok, events} = Prehen.Trace.for_session(gateway_session_id)
    assert Enum.any?(events, &(&1.type == "agent.started"))
  end

  test "projects live status transitions and retains history after stop", %{workspace: workspace} do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "coder", workspace: workspace)

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

    assert row.preview == "echo:hello inbox"

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
             %{kind: :assistant_message, message_id: request_id, text: "echo:hello inbox"}
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

  defp coder_profile, do: PiAgentFixture.profile("coder")
  defp coder_implementation, do: PiAgentFixture.implementation("coder")

  defp set_registry(profiles, implementations) do
    PiAgentFixture.replace_registry!(PiAgentFixture.registry_state(profiles, implementations))
  end
end
