defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest
  import Phoenix.ConnTest

  alias Prehen.Gateway.InboxProjection
  alias Prehen.TestSupport.PiAgentFixture

  @endpoint PrehenWeb.Endpoint

  setup do
    InboxProjection.reset()

    original =
      PiAgentFixture.replace_registry!(
        set_registry_state([fake_profile()], fake_implementations())
      )

    prehen_home = tmp_prehen_home("web_inbox")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    System.put_env("PREHEN_HOME", prehen_home)
    write_profile_home!(prehen_home, "coder")
    write_profile_home!(prehen_home, "zebra")
    write_profile_home!(prehen_home, "alpha")
    write_profile_home!(prehen_home, "unsupported")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "lists sessions for the inbox page" do
    conn = get(build_conn(), "/inbox/sessions")

    assert %{"sessions" => []} = json_response(conn, 200)
  end

  test "lists agents for the inbox page" do
    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)

    assert [
             %{
               "agent" => "coder",
               "name" => "Coder",
               "default" => true,
               "description" => "General coding profile"
             }
           ] = agents
  end

  test "default agent flag follows supported registry order rather than sorted response order" do
    zebra = fake_profile("zebra", "Zebra")
    alpha = fake_profile("alpha", "Alpha")
    set_registry([zebra, alpha], fake_implementations(), ["zebra", "alpha"])

    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)

    assert [
             %{"agent" => "alpha", "default" => false},
             %{"agent" => "zebra", "default" => true}
           ] = Enum.map(agents, &Map.take(&1, ["agent", "default"]))
  end

  test "GET /agents only exposes supported profiles" do
    unsupported = fake_profile("unsupported", "Unsupported")
    coder = fake_profile("coder", "Coder")
    set_registry([unsupported, coder], fake_implementations(), ["coder"])

    conn = get(build_conn(), "/agents")

    assert %{"agents" => [%{"agent" => "coder", "default" => true}]} = json_response(conn, 200)
  end

  test "returns an empty agent list when no agents are configured" do
    set_registry([], [])

    conn = get(build_conn(), "/agents")

    assert %{"agents" => []} = json_response(conn, 200)
  end

  test "supports create detail history and stop through inbox JSON endpoints", %{
    prehen_home: prehen_home
  } do
    conn =
      post(build_conn(), "/inbox/sessions", %{
        "agent" => "coder",
        "provider" => "anthropic",
        "model" => "claude-sonnet"
      })

    assert %{"session_id" => session_id, "agent" => "coder", "status" => "attached"} =
             json_response(conn, 201)

    on_exit(fn -> cleanup_session(session_id) end)

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{"text" => "hello inbox"})

    assert %{"status" => "accepted", "session_id" => ^session_id, "request_id" => request_id} =
             json_response(conn, 202)

    assert {:ok, history_conn} =
             wait_until(fn ->
               conn = get(build_conn(), "/inbox/sessions/#{session_id}/history")

               case json_response(conn, 200) do
                 %{"history" => [_user, _assistant] = history} -> {:ok, history}
                 _ -> :retry
               end
             end)

    assert [
             %{"kind" => "user_message", "message_id" => ^request_id, "text" => "hello inbox"},
             %{
               "kind" => "assistant_message",
               "message_id" => ^request_id,
               "text" => "echo:hello inbox"
             }
           ] = history_conn

    conn = get(build_conn(), "/inbox/sessions/#{session_id}")
    assert %{"session" => session} = json_response(conn, 200)
    assert session["session_id"] == session_id
    assert session["agent_name"] == "coder"
    assert session["status"] in ["idle", "running", "attached"]

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => gateway_session} = json_response(conn, 200)
    assert gateway_session["provider"] == "anthropic"
    assert gateway_session["model"] == "claude-sonnet"
    assert gateway_session["workspace"] == profile_workspace(prehen_home, "coder")

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204) == ""

    assert {:ok, detail_conn} =
             wait_until(fn ->
               conn = get(build_conn(), "/inbox/sessions/#{session_id}")

               case json_response(conn, 200) do
                 %{"session" => %{"status" => "stopped"} = session} -> {:ok, session}
                 _ -> :retry
               end
             end)

    assert detail_conn["session_id"] == session_id
  end

  test "returns a structured create failure when no agents are configured" do
    set_registry([], [])

    conn = post(build_conn(), "/inbox/sessions", %{})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":no_agent_profiles_configured"
  end

  test "rejects workspace overrides for inbox session creation" do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder", "workspace" => "/tmp/other"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":workspace_override_not_supported"
  end

  test "creates an inbox session with the default agent when agent is omitted" do
    unsupported = fake_profile("unsupported", "Unsupported")
    coder = fake_profile("coder", "Coder")
    set_registry([unsupported, coder], fake_implementations(), ["coder"])

    conn = post(build_conn(), "/inbox/sessions", %{})

    assert %{"session_id" => session_id, "agent" => "coder", "status" => "attached"} =
             json_response(conn, 201)

    on_exit(fn -> cleanup_session(session_id) end)
  end

  test "creates an inbox session in the fixed profile workspace", %{prehen_home: prehen_home} do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})

    assert %{"session_id" => session_id, "agent" => "coder", "status" => "attached"} =
             json_response(conn, 201)

    conn = get(build_conn(), "/sessions/#{session_id}")
    assert %{"session" => %{"workspace" => workspace}} = json_response(conn, 200)
    assert workspace == profile_workspace(prehen_home, "coder")
    assert File.dir?(workspace)

    on_exit(fn -> cleanup_session(session_id) end)
  end

  test "returns a structured create failure when the requested profile name is unsupported" do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "missing_profile"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":agent_profile_not_found"
    assert message =~ "missing_profile"
  end

  test "returns a classified create failure when the profile implementation is misconfigured" do
    set_registry([fake_profile()], [])

    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})

    assert %{"error" => %{"type" => "unprocessable_entity", "message" => message}} =
             json_response(conn, 422)

    assert message =~ ":agent_implementation_not_found"
    assert message =~ "coder_impl"
  end

  test "stopping a retained inbox session is idempotent" do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id, "status" => "attached"} = json_response(conn, 201)

    on_exit(fn -> cleanup_session(session_id) end)

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204) == ""

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204) == ""

    conn = get(build_conn(), "/inbox/sessions/#{session_id}")

    assert %{"session" => %{"session_id" => ^session_id, "status" => "stopped"}} =
             json_response(conn, 200)
  end

  test "web inbox flow can create over HTTP and submit over SessionChannel" do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id} = json_response(conn, 201)

    {:ok, _, socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:#{session_id}")

    ref = push(socket, "submit", %{"text" => "hello"})
    assert_reply(ref, :ok, %{"request_id" => request_id}, 1_000)

    assert_push("event", %{
      "type" => "session.output.delta",
      "payload" => %{"message_id" => ^request_id}
    }, 1_000)

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204)

    conn = get(build_conn(), "/inbox/sessions/#{session_id}")

    assert %{"session" => %{"session_id" => ^session_id, "status" => "stopped"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/inbox/sessions/#{session_id}/history")
    assert %{"history" => history} = json_response(conn, 200)

    assert [
             %{"kind" => "user_message", "message_id" => ^request_id, "text" => "hello"},
             %{"kind" => "assistant_message", "message_id" => ^request_id, "text" => "echo:hello"}
           ] = history
  end

  test "stops a live inbox session even when projection state is missing" do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id, "status" => "attached"} = json_response(conn, 201)

    on_exit(fn -> cleanup_session(session_id) end)

    InboxProjection.reset()

    log =
      capture_log(fn ->
        conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
        assert response(conn, 204) == ""

        assert {:ok, %{session_id: ^session_id, status: :stopped, agent_name: "coder"}} =
                 wait_until(fn ->
                   case InboxProjection.fetch_session(session_id) do
                     {:ok, %{status: :stopped, agent_name: "coder"} = row} -> {:ok, row}
                     _ -> :retry
                   end
                 end)
      end)

    refute log =~ "MatchError"
    refute log =~ "lib/prehen/gateway/session_worker.ex:186"
  end

  test "recreates retained row on idempotent delete when registry is already terminal and projection is missing",
       %{} do
    conn = post(build_conn(), "/inbox/sessions", %{"agent" => "coder"})
    assert %{"session_id" => session_id, "status" => "attached"} = json_response(conn, 201)

    on_exit(fn -> cleanup_session(session_id) end)

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204) == ""

    assert {:ok, %{session_id: ^session_id, status: :stopped, agent_name: "coder"}} =
             wait_until(fn ->
               case InboxProjection.fetch_session(session_id) do
                 {:ok, %{status: :stopped, agent_name: "coder"} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    InboxProjection.reset()

    conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
    assert response(conn, 204) == ""

    assert {:ok, %{session_id: ^session_id, status: :stopped, agent_name: "coder"}} =
             wait_until(fn ->
               case InboxProjection.fetch_session(session_id) do
                 {:ok, %{status: :stopped, agent_name: "coder"} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)
  end

  defp fake_profile(name \\ "coder", label \\ "Coder") do
    PiAgentFixture.profile(name,
      label: label,
      description: description_for(name),
      prompt_profile: "#{name}_default"
    )
  end

  defp fake_implementations do
    [
      fake_implementation("coder_impl"),
      fake_implementation("zebra_impl"),
      fake_implementation("alpha_impl")
    ]
  end

  defp fake_implementation(name) do
    profile_name = String.replace_suffix(name, "_impl", "")
    PiAgentFixture.implementation(profile_name, %{}, name: name)
  end

  defp set_registry(profiles, implementations, supported_names \\ nil) do
    PiAgentFixture.replace_registry!(
      set_registry_state(profiles, implementations, supported_names)
    )
  end

  defp set_registry_state(profiles, implementations, supported_names \\ nil) do
    PiAgentFixture.registry_state(profiles, implementations, supported_names)
  end

  defp description_for("coder"), do: "General coding profile"
  defp description_for(name), do: "#{name} profile"

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

  defp cleanup_session(session_id) do
    _ = Prehen.Client.Surface.stop_session(session_id)
    :ok
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
      "prehen_web_inbox_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
