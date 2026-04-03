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

    prehen_home = tmp_prehen_home("platform_runtime")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    System.put_env("PREHEN_HOME", prehen_home)
    write_profile_home!(prehen_home, "coder")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "control plane HTTP endpoints route through gateway sessions", %{prehen_home: prehen_home} do
    conn =
      post(build_conn(), "/sessions", %{
        "agent" => "coder",
        "provider" => "anthropic",
        "model" => "claude-sonnet"
      })

    assert created = json_response(conn, 201)
    assert %{"session_id" => session_id, "agent" => "coder"} = created

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)
    assert session["agent_name"] == "coder"
    assert session["provider"] == "anthropic"
    assert session["model"] == "claude-sonnet"
    assert session["workspace"] == profile_workspace(prehen_home, "coder")

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

  test "POST /sessions rejects workspace overrides once profile workspaces are fixed" do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder", "workspace" => "/tmp/other"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":workspace_override_not_supported"
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
    prehen_home: prehen_home
  } do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)

    assert session["session_id"] == session_id
    assert session["status"] == "attached"
    assert session["workspace"] == profile_workspace(prehen_home, "coder")
    refute Map.has_key?(session, "worker_pid")
  end

  test "GET /sessions/:id omits worker_pid after retained terminal stop" do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    assert :ok = Surface.stop_session(session_id)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)

    assert session["session_id"] == session_id
    assert session["status"] == "stopped"
    refute Map.has_key?(session, "worker_pid")
    assert {:error, :not_found} = Prehen.Gateway.SessionRegistry.fetch_worker(session_id)
  end

  test "POST /sessions/:id/messages returns 400 when message text is missing" do
    conn = post(build_conn(), "/sessions", %{"agent" => "coder"})
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
             Surface.create_session(agent: "coder")

    on_exit(fn -> Surface.stop_session(gateway_session_id) end)

    assert {:ok, _submit} = Surface.submit_message(gateway_session_id, "hello trace")

    Process.sleep(100)

    assert {:ok, events} = Prehen.Trace.for_session(gateway_session_id)
    assert Enum.any?(events, &(&1.type == "agent.started"))
  end

  test "projects live status transitions and retains history after stop" do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "coder")

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

  defp write_profile_home!(prehen_home, profile_name) do
    profile_dir = profile_workspace(prehen_home, profile_name)
    File.mkdir_p!(profile_dir)
    File.write!(Path.join(profile_dir, "SOUL.md"), "SOUL for #{profile_name}.\n")
    File.write!(Path.join(profile_dir, "AGENTS.md"), "AGENTS for #{profile_name}.\n")
  end

  defp profile_workspace(prehen_home, profile_name) do
    Path.join([prehen_home, "profiles", profile_name])
  end

  defp tmp_prehen_home(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_platform_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
