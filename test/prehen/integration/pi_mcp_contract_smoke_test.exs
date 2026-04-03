defmodule Prehen.Integration.PiMCPContractSmokeTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Wrappers.PiLaunchContract

  @skip_reason (
                 if System.get_env("PREHEN_REAL_PI_MCP_CONTRACT") in [nil, ""] do
                   "set PREHEN_REAL_PI_MCP_CONTRACT=1 to run this smoke test"
                 else
                   false
                 end
               )
  @moduletag :integration
  @moduletag skip: @skip_reason

  test "the installed pi exposes a recognized MCP contract" do
    case PiLaunchContract.detect("pi") do
      {:ok, _contract} ->
        assert true

      {:error, :mcp_contract_unavailable} ->
        flunk("installed pi does not expose a recognized MCP contract")

      {:error, reason} ->
        flunk("pi MCP contract probe failed: #{inspect(reason)}")
    end
  end
end
