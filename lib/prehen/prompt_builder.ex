defmodule Prehen.PromptBuilder do
  @moduledoc false

  @global_instructions """
  PREHEN GLOBAL
  You are running inside Prehen.
  Use MCP tools for skills instead of assuming skill content is embedded in this prompt.
  Search for relevant skills with `skills.search` first, then load the selected skill with `skills.load`.
  """

  @spec build(map() | struct(), map(), map()) :: String.t()
  def build(profile_environment, session, capabilities) do
    [
      normalize_section(@global_instructions),
      normalize_section(Map.get(profile_environment, :soul_md)),
      normalize_section(Map.get(profile_environment, :agents_md)),
      runtime_context(session, profile_environment, capabilities)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp runtime_context(session, profile_environment, capabilities) do
    tool_lines =
      capabilities
      |> skill_tools()
      |> Enum.map_join("\n", &"- #{&1}")

    """
    RUNTIME CONTEXT
    profile_name: #{Map.get(session, :profile_name) || Map.get(session, "profile_name")}
    provider: #{Map.get(session, :provider) || Map.get(session, "provider")}
    model: #{Map.get(session, :model) || Map.get(session, "model")}
    workspace: #{Map.get(profile_environment, :workspace_dir)}
    mcp_tools:
    #{tool_lines}
    """
    |> String.trim()
  end

  defp skill_tools(capabilities) when is_map(capabilities) do
    Map.get(capabilities, :skills) || Map.get(capabilities, "skills") || []
  end

  defp skill_tools(_capabilities), do: []

  defp normalize_section(value) when is_binary(value) do
    value
    |> String.trim()
  end

  defp normalize_section(_value), do: ""
end
