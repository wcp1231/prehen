defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.SessionWorker

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

    assert_receive {:gateway_event, %{type: "session.output.delta", gateway_session_id: "gw_1"}}
  end
end
