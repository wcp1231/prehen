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

  test "build_launch_spec enforces json mode and session-selected provider model" do
    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "pi",
      args: ["--provider", "stale", "--sandbox", "workspace-write", "--model", "old"],
      env: %{},
      wrapper: PiCodingAgent
    }

    session_config =
      %SessionConfig{
        profile_name: "coder",
        implementation: implementation,
        provider: "openai",
        model: "gpt-5",
        prompt_profile: "coder_default",
        workspace: "/tmp/prehen_pi_workspace"
      }
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:ok, launch} = PiCodingAgent.build_launch_spec(session_config)

    assert launch.runtime_args == [
             "-lc",
             "cd \"$1\" && shift && exec \"$@\"",
             "prehen-pi",
             "/tmp/prehen_pi_workspace",
             "pi",
             "--mode",
             "json",
             "--provider",
             "openai",
             "--model",
             "gpt-5",
             "--sandbox",
             "workspace-write"
           ]
  end

  test "open_session returns a synthetic agent_session_id without launching pi" do
    workspace = tmp_workspace_path("open_session_only")
    launch_marker = Path.join(workspace, "launch_marker")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_LAUNCH_MARKER" => launch_marker})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_open_only",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert is_binary(agent_session_id) and agent_session_id != ""
    refute File.exists?(launch_marker)

    assert :ok = PiCodingAgent.stop(wrapper)
  end

  test "open_session returns capability_failed instead of crashing the wrapper when workspace is missing" do
    session_config =
      session_config(nil, implementation: fake_pi_implementation())

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:error, :capability_failed} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_open_missing_workspace",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default"
             })

    assert Process.alive?(wrapper)
    assert :ok = PiCodingAgent.stop(wrapper)
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

  test "ignores pi message lifecycle events that do not carry assistant output" do
    workspace = tmp_workspace_path("message_lifecycle")

    session_config =
      session_config(
        workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "message_lifecycle"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_message_lifecycle",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_message_lifecycle",
               parts: [%{type: "text", text: "ping"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_message_lifecycle", "text" => "echo:ping"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_message_lifecycle"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)
  end

  test "streams output when pi waits for stdin EOF before emitting the header" do
    workspace = tmp_workspace_path("eof_gated_turn")

    session_config =
      session_config(
        workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "wait_for_eof_before_header"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_eof_gated_turn",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_eof_gated_turn",
               parts: [%{type: "text", text: "ping"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_eof_gated_turn", "text" => "echo:ping"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_eof_gated_turn"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)
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

  test "includes prior conversation context in the second turn launch" do
    workspace = tmp_workspace_path("multi_turn")

    session_config =
      session_config(workspace, implementation: fake_pi_implementation())

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_multi_turn",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_turn_1",
               parts: [%{type: "text", text: "first"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_turn_1", "text" => "echo:first"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_turn_1"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{conversation_state: [%{user_text: "first", assistant_text: "echo:first"}]} =
             :sys.get_state(wrapper)

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_turn_2",
               parts: [%{type: "text", text: "second"}]
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{"message_id" => "msg_turn_2", "text" => text}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert text =~ "user:first"
    assert text =~ "assistant:echo:first"
    assert text =~ "user:second"

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_turn_2"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{
             conversation_state: [
               %{user_text: "first", assistant_text: "echo:first"},
               %{user_text: "second", assistant_text: ^text}
             ]
           } = :sys.get_state(wrapper)
  end

  test "stops the current host when agent_end arrives" do
    workspace = tmp_workspace_path("linger_after_end")
    exit_marker = Path.join(workspace, "linger_marker")

    session_config =
      session_config(workspace,
        implementation:
          fake_pi_implementation(%{
            "FAKE_PI_MODE" => "linger_after_end",
            "FAKE_PI_EXIT_MARKER" => exit_marker
          })
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_linger",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_linger",
               parts: [%{type: "text", text: "done"}]
             })

    assert {:ok, %{"type" => "session.output.delta"}} = PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok, %{"type" => "session.output.completed"}} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{current_run: nil, managed_hosts: managed_hosts, status: :idle} =
             :sys.get_state(wrapper)

    assert MapSet.size(managed_hosts) == 0

    Process.sleep(1_200)

    refute File.exists?(exit_marker)
  end

  test "ignores trailing stdout buffered after agent_end in the same chunk" do
    workspace = tmp_workspace_path("same_chunk_after_agent_end")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "same_chunk_after_agent_end"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_same_chunk",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_same_chunk_1",
               parts: [%{type: "text", text: "first"}]
             })

    assert {:ok, %{"type" => "session.output.delta"}} = PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok, %{"type" => "session.output.completed"}} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{current_run: nil, status: :idle} = :sys.get_state(wrapper)

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_same_chunk_2",
               parts: [%{type: "text", text: "second"}]
             })

    assert {:ok, %{"type" => "session.output.delta"}} = PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok, %{"type" => "session.output.completed"}} =
             PiCodingAgent.recv_event(wrapper, 1_000)
  end

  test "emits error then completed when the stream becomes malformed" do
    workspace = tmp_workspace_path("malformed")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "malformed_after_header"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_malformed",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_malformed",
               parts: [%{type: "text", text: "boom"}]
             })

    assert {:ok,
            %{
              "type" => "session.error",
              "payload" => %{"message_id" => "msg_malformed", "reason" => "contract_failed"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_malformed"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{current_run: nil, status: :idle} = :sys.get_state(wrapper)
  end

  test "treats arbitrary JSON after the header as contract_failed at runtime" do
    workspace = tmp_workspace_path("unknown_event_runtime")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "unknown_event_then_nonzero"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_unknown_runtime",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_unknown_runtime",
               parts: [%{type: "text", text: "boom"}]
             })

    assert {:ok,
            %{
              "type" => "session.error",
              "payload" => %{
                "message_id" => "msg_unknown_runtime",
                "reason" => "contract_failed"
              }
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_unknown_runtime"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)
  end

  test "emits error then completed when the child exits nonzero after the header" do
    workspace = tmp_workspace_path("nonzero_exit")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "nonzero_exit"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_nonzero",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_nonzero",
               parts: [%{type: "text", text: "boom"}]
             })

    assert {:ok,
            %{
              "type" => "session.error",
              "payload" => %{"message_id" => "msg_nonzero", "reason" => "exit_status:17"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_nonzero"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{current_run: nil, status: :idle} = :sys.get_state(wrapper)
  end

  test "emits error then completed when cancelling an active run" do
    workspace = tmp_workspace_path("cancel")

    session_config =
      session_config(workspace,
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "busy"})
      )

    assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: agent_session_id}} =
             PiCodingAgent.open_session(wrapper, %{
               gateway_session_id: "gw_cancel",
               provider: "openai",
               model: "gpt-5",
               prompt_profile: "coder_default",
               workspace: workspace
             })

    assert :ok =
             PiCodingAgent.send_message(wrapper, %{
               agent_session_id: agent_session_id,
               message_id: "msg_cancel",
               parts: [%{type: "text", text: "wait"}]
             })

    assert :ok =
             PiCodingAgent.send_control(wrapper, %{
               agent_session_id: agent_session_id,
               command: "stop"
             })

    assert {:ok,
            %{
              "type" => "session.error",
              "payload" => %{"message_id" => "msg_cancel", "reason" => "cancelled"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert {:ok,
            %{
              "type" => "session.output.completed",
              "payload" => %{"message_id" => "msg_cancel"}
            }} =
             PiCodingAgent.recv_event(wrapper, 1_000)

    assert %{current_run: nil, status: :idle} = :sys.get_state(wrapper)
  end

  test "support_check accepts a minimal native stream that starts with a session header" do
    session_config =
      session_config(tmp_workspace_path("support_check_ok"),
        implementation: fake_pi_implementation()
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check accepts pi runs that wait for stdin EOF before emitting output" do
    session_config =
      session_config(tmp_workspace_path("support_check_wait_for_eof"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "wait_for_eof_before_header"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check accepts pi message lifecycle events before assistant output" do
    session_config =
      session_config(tmp_workspace_path("support_check_message_lifecycle"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "message_lifecycle"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check accepts a header-only stream that remains stable through startup grace" do
    session_config =
      session_config(tmp_workspace_path("support_check_delayed_nonzero"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "delayed_nonzero"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  test "support_check rejects immediate nonzero failure after a valid post-header event" do
    session_config =
      session_config(tmp_workspace_path("support_check_event_then_nonzero"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "event_then_nonzero"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check leaves no probe messages in the caller mailbox after success" do
    previous_trap_exit? = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit?) end)

    session_config =
      session_config(tmp_workspace_path("support_check_mailbox_clean"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "delayed_nonzero"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert :ok = PiCodingAgent.support_check(session_config)
    refute_receive {:executable_host, _, _}, 200
    refute_receive {:EXIT, _, _}, 200
  end

  test "support_check rejects immediate nonzero failure after a valid session header" do
    session_config =
      session_config(tmp_workspace_path("support_check_immediate_nonzero"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "nonzero_exit"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
  end

  test "support_check rejects arbitrary JSON after the header" do
    session_config =
      session_config(tmp_workspace_path("support_check_unknown_event"),
        implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "unknown_event_then_nonzero"})
      )
      |> Map.put(:prompt_context, "You are Prehen coder.")

    assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
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
