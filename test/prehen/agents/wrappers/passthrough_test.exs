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
end
