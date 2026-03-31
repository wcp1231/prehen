defmodule Prehen.Agents.Wrappers.PassthroughTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrappers.Passthrough

  test "opens submits and receives normalized frames through the wrapper contract" do
    implementation = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_stdio_agent.exs"],
      env: %{},
      wrapper: Passthrough
    }

    session_config = %SessionConfig{
      profile_name: "coder",
      implementation: implementation,
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace: "/tmp/prehen_wrapper_test"
    }

    assert {:ok, wrapper} = Passthrough.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: "agent_gw_wrapper"}} =
             Passthrough.open_session(wrapper, %{gateway_session_id: "gw_wrapper"})

    assert :ok =
             Passthrough.send_message(wrapper, %{
               message_id: "msg_1",
               parts: [%{type: "text", text: "hi"}]
             })

    assert {:ok, %{"type" => "session.output.delta"}} = Passthrough.recv_event(wrapper, 1_000)
  end

  test "returns an error when gateway_session_id is missing" do
    implementation = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_stdio_agent.exs"],
      env: %{},
      wrapper: Passthrough
    }

    session_config = %SessionConfig{
      profile_name: "coder",
      implementation: implementation,
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace: "/tmp/prehen_wrapper_test"
    }

    assert {:ok, wrapper} = Passthrough.start_link(session_config: session_config)
    assert {:error, :missing_gateway_session_id} = Passthrough.open_session(wrapper, %{})
    assert Process.alive?(wrapper)
  end

  test "allows session open to take longer than five seconds" do
    implementation = %Implementation{
      name: "slow_stdio_impl",
      command: "python3",
      args: [
        "-c",
        """
        import json, sys, time
        line = sys.stdin.readline()
        frame = json.loads(line)
        time.sleep(5.2)
        gateway_session_id = frame["payload"]["gateway_session_id"]
        print(json.dumps({"type": "session.opened", "payload": {"agent_session_id": f"agent_{gateway_session_id}"}}), flush=True)
        """
      ],
      env: %{},
      wrapper: Passthrough
    }

    session_config = %SessionConfig{
      profile_name: "coder",
      implementation: implementation,
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace: "/tmp/prehen_wrapper_test"
    }

    assert {:ok, wrapper} = Passthrough.start_link(session_config: session_config)

    assert {:ok, %{agent_session_id: "agent_gw_slow"}} =
             Passthrough.open_session(wrapper, %{gateway_session_id: "gw_slow"})
  end
end
