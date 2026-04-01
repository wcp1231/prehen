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

  test "launches an executable with wrapper-controlled prompt provider model and workspace" do
    workspace = tmp_workspace_path("runtime")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", compatibility_probe_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert :ok = PiCodingAgent.support_check(session_config)
    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: "agent_pi"}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_pi",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace,
               prompt: %{system: "You are Prehen coder."}
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: "agent_pi",
               message_id: "msg_pi",
               parts: [%{type: "text", text: "ping"}]
             })

    assert {:ok, %{"type" => "session.output.delta", "payload" => %{"text" => text}}} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert_validation_report!(text, workspace)

    assert {:ok, %{"type" => "session.output.completed"}} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    ref = Process.monitor(wrapper)
    assert :ok = PiCodingAgent.stop(wrapper)
    assert_receive {:DOWN, ^ref, :process, ^wrapper, _reason}, 1_000
  end

  test "support_check rejects startable executables that do not yield a stable opened session" do
    workspace = tmp_workspace_path("contract_failed")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", unstable_open_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies open-time process exit as contract failure" do
    workspace = tmp_workspace_path("open_exit")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", open_exit_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  @tag timeout: 25_000
  test "support_check classifies open-time hang timeout as contract failure" do
    workspace = tmp_workspace_path("open_timeout")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", open_timeout_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies policy rejection directly" do
    workspace = tmp_workspace_path("policy_rejected")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", compatibility_probe_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )
      |> Map.put(:workspace_policy, %{mode: "disabled"})

    assert {:error, :policy_rejected} = PiCodingAgent.support_check(session_config)
  end

  test "support_check classifies capability failures directly" do
    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "python3",
      args: ["-u", "-c", compatibility_probe_script()],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config("relative/workspace",
        implementation: implementation,
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

  @tag skip:
         if(System.get_env("PI_CODING_AGENT_BIN"),
           do: false,
           else: "set PI_CODING_AGENT_BIN to run the real executable wrapper validation"
         )
  test "validates the configured pi-coding-agent executable through the wrapper" do
    workspace = tmp_workspace_path("real")

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: System.fetch_env!("PI_CODING_AGENT_BIN"),
      args: [],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      session_config(workspace,
        implementation: implementation,
        prompt_context: "You are Prehen coder."
      )

    assert :ok = PiCodingAgent.support_check(session_config)
    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_pi_real",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace,
               prompt: %{system: "You are Prehen coder."}
             })

    assert is_binary(agent_session_id) and agent_session_id != ""

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_pi_real",
               parts: [%{type: "text", text: "ping"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_pi_real", "text" => text}
            }} =
             PiCodingAgent.recv_event(wrapper, 5_000)

    assert is_binary(text) and text != ""

    assert {:ok,
            %{"type" => "session.output.completed", "payload" => %{"message_id" => "msg_pi_real"}}} =
             PiCodingAgent.recv_event(wrapper, 5_000)

    ref = Process.monitor(wrapper)
    assert :ok = PiCodingAgent.stop(wrapper)
    assert_receive {:DOWN, ^ref, :process, ^wrapper, _reason}, 1_000
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

  defp compatibility_probe_script do
    """
    import json
    import os
    import sys

    state = {}

    for raw in sys.stdin:
        frame = json.loads(raw)
        frame_type = frame.get("type")
        payload = frame.get("payload", {})

        if frame_type == "session.open":
            state["provider_open"] = payload.get("provider")
            state["model_open"] = payload.get("model")
            state["workspace_open"] = payload.get("workspace")
            state["prompt_open"] = json.dumps(payload.get("prompt"), sort_keys=True)

            sys.stdout.write(json.dumps({
                "type": "session.opened",
                "payload": {"agent_session_id": "agent_pi"}
            }) + "\\n")
            sys.stdout.flush()
        elif frame_type == "session.message":
            report = {
                "provider_env": os.environ.get("PREHEN_PROVIDER"),
                "model_env": os.environ.get("PREHEN_MODEL"),
                "workspace_env": os.environ.get("PREHEN_WORKSPACE"),
                "prompt_env": os.environ.get("PREHEN_PROMPT"),
                "cwd": os.getcwd(),
                "provider_open": state.get("provider_open"),
                "model_open": state.get("model_open"),
                "workspace_open": state.get("workspace_open"),
                "prompt_open": state.get("prompt_open")
            }

            sys.stdout.write(json.dumps({
                "type": "session.output.delta",
                "payload": {
                    "agent_session_id": payload.get("agent_session_id", "agent_pi"),
                    "message_id": payload["message_id"],
                    "text": json.dumps(report, sort_keys=True)
                }
            }) + "\\n")
            sys.stdout.write(json.dumps({
                "type": "session.output.completed",
                "payload": {
                    "agent_session_id": payload.get("agent_session_id", "agent_pi"),
                    "message_id": payload["message_id"]
                }
            }) + "\\n")
            sys.stdout.flush()
        elif frame_type == "session.control":
            sys.exit(0)
    """
  end

  defp unstable_open_script do
    """
    import json
    import sys

    for raw in sys.stdin:
        frame = json.loads(raw)
        if frame.get("type") == "session.open":
            sys.stdout.write(json.dumps({
                "type": "session.opened",
                "payload": {"ready": True}
            }) + "\\n")
            sys.stdout.flush()
    """
  end

  defp open_exit_script do
    """
    import json
    import sys

    for raw in sys.stdin:
        frame = json.loads(raw)
        if frame.get("type") == "session.open":
            sys.exit(17)
    """
  end

  defp open_timeout_script do
    """
    import json
    import time

    for raw in __import__("sys").stdin:
        frame = json.loads(raw)
        if frame.get("type") == "session.open":
            time.sleep(17)
    """
  end

  defp assert_validation_report!(text, workspace) do
    report =
      case Jason.decode(text) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("""
          expected the executable to echo a JSON validation report in the first delta, got:
          #{inspect(text)}
          decode error:
          #{inspect(reason)}
          """)
      end

    assert report["provider_env"] == "openai"
    assert report["model_env"] == "gpt-5"
    assert report["workspace_env"] == workspace
    assert report["provider_open"] == "openai"
    assert report["model_open"] == "gpt-5"
    assert report["workspace_open"] == workspace
    assert same_path?(report["cwd"], workspace)
    assert report["prompt_env"] =~ "You are Prehen coder."
    assert report["prompt_open"] =~ "You are Prehen coder."
  end

  defp same_path?(left, right) do
    left = Path.expand(left)
    right = Path.expand(right)

    left == right || left == "/private" <> right || "/private" <> left == right
  end
end
