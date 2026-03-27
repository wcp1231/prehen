defmodule Prehen.Gateway.SessionRegistryTest do
  use ExUnit.Case, async: false

  test "stores route metadata for a gateway session" do
    assert :ok =
             Prehen.Gateway.SessionRegistry.put(%{
               gateway_session_id: "gw_1",
               agent_name: "fake_stdio",
               agent_session_id: "agent_gw_1",
               status: :attached
             })

    assert {:ok, %{agent_session_id: "agent_gw_1"}} =
             Prehen.Gateway.SessionRegistry.fetch("gw_1")
  end

  test "returns not found for unknown gateway session id" do
    assert {:error, :not_found} = Prehen.Gateway.SessionRegistry.fetch("missing")
  end
end
