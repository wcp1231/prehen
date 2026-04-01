defmodule Prehen.Agents.Registry do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def all, do: GenServer.call(__MODULE__, :all)
  def fetch(name), do: GenServer.call(__MODULE__, {:fetch, name})
  def fetch_implementation(name), do: GenServer.call(__MODULE__, {:fetch_implementation, name})

  def fetch!(name) do
    case fetch(name) do
      {:ok, profile} -> profile
      {:error, :not_found} -> raise KeyError, key: to_string(name), term: %{}
    end
  end

  def fetch_implementation!(name) do
    case fetch_implementation(name) do
      {:ok, implementation} -> implementation
      {:error, :not_found} -> raise KeyError, key: to_string(name), term: %{}
    end
  end

  @impl true
  def init(opts) do
    profiles = Keyword.get(opts, :profiles, [])
    implementations = Keyword.get(opts, :implementations, [])

    {:ok, build_state(profiles, implementations)}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, supported_ordered(state), state}
  end

  def handle_call({:fetch, name}, _from, state) do
    {:reply, Map.fetch(supported_by_name(state), to_string(name)), state}
  end

  def handle_call({:fetch_implementation, name}, _from, state) do
    {:reply, Map.fetch(state.implementations_by_name, to_string(name)), state}
  end

  defp build_state(profiles, implementations) do
    implementations_by_name =
      Map.new(implementations, fn
        %Implementation{name: name} = implementation -> {name, implementation}
        implementation -> {implementation.name, implementation}
      end)

    supported_profiles =
      Enum.filter(profiles, &supported_profile?(&1, implementations_by_name))

    %{
      ordered: profiles,
      by_name: Map.new(profiles, fn %Profile{name: name} = profile -> {name, profile} end),
      supported_ordered: supported_profiles,
      supported_by_name:
        Map.new(supported_profiles, fn %Profile{name: name} = profile -> {name, profile} end),
      implementations_ordered: implementations,
      implementations_by_name: implementations_by_name
    }
  end

  defp supported_profile?(%Profile{} = profile, implementations_by_name) do
    with {:ok, implementation} <- implementation_for_profile(profile, implementations_by_name),
         {:ok, wrapper} <- wrapper_module(implementation),
         true <- function_exported?(wrapper, :support_check, 1),
         :ok <- wrapper.support_check(support_check_session_config(profile, implementation)) do
      true
    else
      _ -> false
    end
  end

  defp supported_profile?(_profile, _implementations_by_name), do: false

  defp implementation_for_profile(
         %Profile{implementation: implementation_name},
         implementations_by_name
       )
       when is_binary(implementation_name) and implementation_name != "" do
    Map.fetch(implementations_by_name, implementation_name)
  end

  defp implementation_for_profile(
         %Profile{command: command, args: args, env: env, wrapper: wrapper} = profile,
         _implementations_by_name
       )
       when (is_binary(command) and command != "") or is_list(command) do
    with {:ok, normalized_command, normalized_args} <- normalize_command(command, args),
         {:ok, normalized_wrapper} <- wrapper_module(%{wrapper: wrapper}) do
      {:ok,
       %Implementation{
         name: profile.implementation || profile.name,
         command: normalized_command,
         args: normalized_args,
         env: normalize_env(env),
         wrapper: normalized_wrapper
       }}
    end
  end

  defp implementation_for_profile(_profile, _implementations_by_name), do: {:error, :not_found}

  defp support_check_session_config(%Profile{} = profile, %Implementation{} = implementation) do
    %SessionConfig{
      profile_name: profile.name,
      provider: profile.default_provider,
      model: profile.default_model,
      prompt_profile: profile.prompt_profile,
      workspace_policy: profile.workspace_policy,
      implementation: implementation,
      workspace: support_check_workspace()
    }
  end

  defp support_check_workspace do
    System.tmp_dir() || File.cwd!()
  end

  defp wrapper_module(%Implementation{wrapper: wrapper}), do: wrapper_module(%{wrapper: wrapper})

  defp wrapper_module(%{wrapper: wrapper}) when is_atom(wrapper), do: {:ok, wrapper}
  defp wrapper_module(_implementation), do: {:error, :missing_wrapper}

  defp normalize_command([command | extra_args], args) when is_binary(command) and command != "" do
    {:ok, command, Enum.map(extra_args ++ List.wrap(args), &to_string/1)}
  end

  defp normalize_command(command, args) when is_binary(command) and command != "" do
    {:ok, command, Enum.map(List.wrap(args), &to_string/1)}
  end

  defp normalize_command(_command, _args), do: {:error, :missing_command}

  defp normalize_env(env) when is_map(env),
    do: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp normalize_env(_env), do: %{}

  defp supported_ordered(state), do: Map.get(state, :supported_ordered, state.ordered)
  defp supported_by_name(state), do: Map.get(state, :supported_by_name, state.by_name)
end
