defmodule Prehen.MCP.ToolDispatch do
  @moduledoc false

  alias Prehen.MCP.Tools.Skills

  @tools [
    %{"name" => "skills.search", "description" => "Search visible skills"},
    %{"name" => "skills.load", "description" => "Load one visible skill"}
  ]

  @spec call(map(), map()) :: {:ok, map()} | {:error, :method_not_found | :not_found}
  def call(context, %{"method" => "tools/list"}) do
    {:ok, %{"tools" => available_tools(context)}}
  end

  def call(context, %{"method" => "tools/call", "params" => %{"name" => name} = params})
      when is_map(context) and is_binary(name) and name != "" do
    if tool_allowed?(context, name) do
      dispatch_tool(context, name, Map.get(params, "arguments", %{}))
    else
      {:error, :method_not_found}
    end
  end

  def call(_context, _payload), do: {:error, :method_not_found}

  defp dispatch_tool(context, "skills.search", args), do: Skills.search(context, args)
  defp dispatch_tool(context, "skills.load", args), do: Skills.load(context, args)
  defp dispatch_tool(_context, _name, _args), do: {:error, :method_not_found}

  defp available_tools(context) do
    Enum.filter(@tools, fn %{"name" => name} -> tool_allowed?(context, name) end)
  end

  defp tool_allowed?(context, name) do
    case capabilities(context) do
      :all -> true
      allowed when is_list(allowed) -> name in allowed
    end
  end

  defp capabilities(context) when is_map(context) do
    Map.get(context, :capabilities) || Map.get(context, "capabilities") || :all
  end
end
