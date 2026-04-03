defmodule Prehen.Agents.Wrappers.PiLaunchContractTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.Wrappers.PiLaunchContract

  test "returns a classified error when pi help exposes no MCP flags or env contract" do
    help = "pi --help\n--provider\n--model\n"

    assert {:error, :mcp_contract_unavailable} = PiLaunchContract.detect_from_help(help)
  end

  test "detects HTTP flag style when present" do
    help = "pi --help\n--mcp-url <url>\n--mcp-bearer-token <token>\n"

    assert {:ok, {:http_flags, %{url_flag: "--mcp-url", token_flag: "--mcp-bearer-token"}}} =
             PiLaunchContract.detect_from_help(help)
  end

  test "detects HTTP env style when present" do
    help = "pi --help\nPREHEN_MCP_URL\nPREHEN_MCP_TOKEN\n"

    assert {:ok, {:http_env, %{url_env: "PREHEN_MCP_URL", token_env: "PREHEN_MCP_TOKEN"}}} =
             PiLaunchContract.detect_from_help(help)
  end

  test "probes a script-backed wrapper using the launcher prefix" do
    assert {:ok, {:http_flags, %{url_flag: "--mcp-url", token_flag: "--mcp-bearer-token"}}} =
             PiLaunchContract.detect(
               python_command(),
               [fake_pi_script_path()],
               %{"FAKE_PI_HELP_CONTRACT" => "http_flags"}
             )
  end

  defp python_command do
    System.find_executable("python3") || "python3"
  end

  defp fake_pi_script_path do
    Path.expand("../../../support/fake_pi_json_agent.py", __DIR__)
  end
end
