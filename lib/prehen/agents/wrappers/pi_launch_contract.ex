defmodule Prehen.Agents.Wrappers.PiLaunchContract do
  @moduledoc false

  @help_timeout_ms 2_000

  def detect(command \\ "pi", launcher_prefix \\ [], env \\ %{}) do
    args = normalize_args(launcher_prefix) ++ ["--help"]

    task =
      Task.async(fn ->
        System.cmd(command, args, stderr_to_stdout: true, env: normalize_env(env))
      end)

    Process.unlink(task.pid)

    case Task.yield(task, @help_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> detect_from_help(output)
      {:ok, {_output, _status}} -> {:error, :command_help_failed}
      nil -> {:error, :command_help_failed}
    end
  rescue
    _error -> {:error, :command_help_failed}
  catch
    :exit, _reason -> {:error, :command_help_failed}
  end

  def detect_from_help(help) when is_binary(help) do
    cond do
      help =~ "--mcp-url" and help =~ "--mcp-bearer-token" ->
        {:ok, {:http_flags, %{url_flag: "--mcp-url", token_flag: "--mcp-bearer-token"}}}

      help =~ "PREHEN_MCP_URL" and help =~ "PREHEN_MCP_TOKEN" ->
        {:ok, {:http_env, %{url_env: "PREHEN_MCP_URL", token_env: "PREHEN_MCP_TOKEN"}}}

      true ->
        {:error, :mcp_contract_unavailable}
    end
  end

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}
end
