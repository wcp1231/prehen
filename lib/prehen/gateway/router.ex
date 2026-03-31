defmodule Prehen.Gateway.Router do
  @moduledoc false

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry

  @spec route(keyword()) :: {:ok, struct()} | {:error, term()}
  def route(opts \\ []) do
    case normalize_agent_name(Keyword.get(opts, :agent) || Keyword.get(opts, :agent_name)) do
      nil ->
        route_default()

      name ->
        try do
          name
          |> Registry.fetch!()
          |> bind_implementation()
        rescue
          KeyError -> {:error, {:agent_profile_not_found, name}}
        end
    end
  end

  @spec select_agent(keyword()) :: {:ok, struct()} | {:error, term()}
  def select_agent(opts \\ []), do: route(opts)

  defp route_default do
    case Registry.all() do
      [profile | _rest] -> bind_implementation(profile)
      [] -> {:error, :no_agent_profiles_configured}
    end
  end

  defp bind_implementation(%Profile{implementation: implementation} = profile)
       when is_binary(implementation) and implementation != "" do
    try do
      {:ok, Profile.bind_implementation(profile, Registry.fetch_implementation!(implementation))}
    rescue
      KeyError -> {:error, {:agent_implementation_not_found, implementation}}
    end
  end

  defp bind_implementation(%Profile{command: command} = profile)
       when is_binary(command) or is_list(command) do
    {:ok, profile}
  end

  defp bind_implementation(_profile), do: {:error, :invalid_agent_profile}

  defp normalize_agent_name(nil), do: nil

  defp normalize_agent_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_agent_name(name), do: to_string(name)
end
