defmodule Prehen.Agents.Wrappers.PiCodingAgentTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrappers.PiCodingAgent

  test "maps session policy into the pi-coding-agent launch contract" do
    session_config =
      %SessionConfig{
        profile_name: "coder",
        provider: "openai",
        model: "gpt-5",
        prompt_profile: "coder_default",
        workspace: "/tmp/prehen_pi_workspace"
      }
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:ok, launch} = PiCodingAgent.build_launch_spec(session_config)
    assert launch.cwd == "/tmp/prehen_pi_workspace"
    assert launch.env["PREHEN_PROVIDER"] == "openai"
    assert launch.env["PREHEN_MODEL"] == "gpt-5"
    assert launch.prompt_payload =~ "You are Prehen coder."
  end

  test "opens a synthetic session and maps pi text deltas into gateway frames" do
    workspace = tmp_workspace_path("native")

    session_config =
      session_config(workspace, implementation: fake_pi_implementation())

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_pi_native",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert is_binary(agent_session_id) and agent_session_id != ""

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_pi_native",
               parts: [%{type: "text", text: "ping"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_pi_native", "text" => "echo:ping"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_pi_native"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    ref = Process.monitor(wrapper)
    assert :ok = PiCodingAgent.stop(wrapper)
    assert_receive {:DOWN, ^ref, :process, ^wrapper, _reason}, 1_000
  end

  test "rejects a second turn while a run is still active" do
    workspace = tmp_workspace_path("busy")

    session_config =
      session_config(
        workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "busy"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_busy",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_busy_1",
               parts: [%{type: "text", text: "first"}]
             })

    assert {:error, :session_busy} =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_busy_2",
               parts: [%{type: "text", text: "second"}]
             })

    assert :ok = PiCodingAgent.stop(wrapper)
  end

  test "support_check accepts a minimal native stream that starts with a session header" do
    session_config =
      session_config(tmp_workspace_path("support_check_ok"),
        implementation: fake_pi_implementation()
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check succeeds once a valid session header is observed" do
    workspace = tmp_workspace_path("support_check_header_only")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: python_command(),
      args: [
        "-u",
        "-c",
        "import json,sys; sys.stdout.write(json.dumps({'type':'session','id':'probe'}) + '\\n'); sys.stdout.flush(); sys.exit(17)"
      ],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check rejects a stream without a valid session header" do
    session_config =
      session_config(
        tmp_workspace_path("invalid_header"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "invalid_header"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies policy rejection directly" do
    workspace = tmp_workspace_path("policy_rejected")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(),
        prompt_context: "You are Prehen coder."
      )
      |> Map.put(:workspace_policy, %{mode: "disabled"})

    assert {:error, :policy_rejected} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies capability failures directly" do
    session_config =
      session_config("relative/workspace",
        implementation: fake_pi_implementation(),
        prompt_context: "You are Prehen coder."
      )

    assert {:error, :capability_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies launch failures directly" do
    workspace = tmp_workspace_path("launch_failed")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "",
      args: [],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert {:error, :launch_failed} = PiCodingAgent.support_check(session_config)
  end

  defp session_config(workspace, opts) do
    implementation = Keyword.get(opts, :implementation)

    %SessionConfig{
      profile_name: "coder",
      implementation: implementation,
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace: workspace
    }
    |> Map.put(:prompt_context, Keyword.get(opts, :prompt_context))
  end

  defp fake_pi_implementation(extra_env \\ %{}) do
    %Implementation{
      name: "pi_coding_agent",
      command: python_command(),
      args: [fake_pi_script_path(), "--mode", "json"],
      env: Map.merge(%{}, extra_env),
      wrapper: PiCodingAgent
    }
  end

  defp python_command do
    System.find_executable("python3") || "python3"
  end

  defp fake_pi_script_path do
    Path.expand("../../../support/fake_pi_json_agent.py", __DIR__)
  end

  defp tmp_workspace_path(label) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_pi_coding_agent_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    workspace
  end
end
