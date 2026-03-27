defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Profile
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker

  setup do
    original_state = :sys.get_state(Prehen.Agents.Registry)

    fake_profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    :sys.replace_state(Prehen.Agents.Registry, fn _ ->
      %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
    end)

    on_exit(fn ->
      :sys.replace_state(Prehen.Agents.Registry, fn _ -> original_state end)
    end)

    :ok
  end

  test "forwards normalized output delta events with gateway session metadata" do
    assert {:ok, pid} =
             SessionWorker.start_link(
               gateway_session_id: "gw_1",
               agent_name: "fake_stdio",
               test_pid: self()
             )

    assert :ok =
             SessionWorker.submit_message(pid, %{
               role: "user",
               parts: [%{type: "text", text: "hi"}]
             })

    assert {:ok, %{agent_session_id: "agent_gw_1", status: :attached}} =
             SessionRegistry.fetch("gw_1")

    assert_receive {:gateway_event, event}
    assert event.type == "session.output.delta"
    assert event.gateway_session_id == "gw_1"
    assert event.agent_session_id == "agent_gw_1"
    assert event.agent == "fake_stdio"
    assert event.seq == 1

    assert event.payload == %{
             "agent_session_id" => "agent_gw_1",
             "message_id" => "message_1",
             "text" => "hi"
           }
  end
end
