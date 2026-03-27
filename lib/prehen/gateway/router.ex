defmodule Prehen.Gateway.Router do
  @moduledoc false

  alias Prehen.Agents.Registry

  @spec route(keyword()) :: {:ok, struct()} | {:error, term()}
  def route(opts \\ []) do
    case normalize_agent_name(Keyword.get(opts, :agent) || Keyword.get(opts, :agent_name)) do
      nil ->
        route_default()

      name ->
        try do
          {:ok, Registry.fetch!(name)}
        rescue
          KeyError -> {:error, {:agent_profile_not_found, name}}
        end
    end
  end

  @spec select_agent(keyword()) :: {:ok, struct()} | {:error, term()}
  def select_agent(opts \\ []), do: route(opts)

  defp route_default do
    case Registry.all() do
      [profile | _rest] -> {:ok, profile}
      [] -> {:error, :no_agent_profiles_configured}
    end
  end

  defp normalize_agent_name(nil), do: nil

  defp normalize_agent_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_agent_name(name), do: to_string(name)
end
