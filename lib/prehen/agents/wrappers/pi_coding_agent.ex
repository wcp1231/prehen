defmodule Prehen.Agents.Wrappers.PiCodingAgent do
  @moduledoc false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Agents.Wrappers.ExecutableHost
  alias Prehen.Agents.Wrappers.Passthrough
  alias Prehen.Config

  @behaviour Wrapper

  @shell_command System.find_executable("sh") || "/bin/sh"
  @rejected_workspace_policy_modes ~w(disabled off unmanaged)

  @impl Wrapper
  def start_link(opts) do
    session_config = Keyword.fetch!(opts, :session_config)

    with {:ok, passthrough_session_config} <- build_passthrough_session_config(session_config) do
      opts
      |> Keyword.put(:session_config, passthrough_session_config)
      |> Passthrough.start_link()
    end
  end

  @impl Wrapper
  def open_session(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    Passthrough.open_session(wrapper, attrs)
  end

  @impl Wrapper
  def send_message(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    Passthrough.send_message(wrapper, attrs)
  end

  @impl Wrapper
  def send_control(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    Passthrough.send_control(wrapper, attrs)
  end

  @impl Wrapper
  def recv_event(wrapper, timeout \\ 5_000) when is_pid(wrapper) do
    Passthrough.recv_event(wrapper, timeout)
  end

  @impl Wrapper
  def stop(wrapper) when is_pid(wrapper) do
    Passthrough.stop(wrapper)
  end

  @impl Wrapper
  def support_check(%{__struct__: SessionConfig} = session_config) do
    with {:ok, launch} <- build_launch_spec(session_config),
         {:ok, _target} <- classify_target_resolution(launch),
         :ok <- classify_passthrough_support(launch) do
      :ok
    else
      {:error, reason} when reason in [:capability_failed, :contract_failed, :policy_rejected] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :launch_failed}
    end
  end

  def support_check(_session_config), do: {:error, :contract_failed}

  def build_launch_spec(%{__struct__: SessionConfig} = session_config) do
    with :ok <- classify_policy(session_config),
         {:ok, provider} <- fetch_required_string(session_config, :provider, :capability_failed),
         {:ok, model} <- fetch_required_string(session_config, :model, :capability_failed),
         {:ok, prompt_profile} <-
           fetch_required_string(session_config, :prompt_profile, :capability_failed),
         {:ok, workspace} <- workspace_root(session_config),
         {:ok, prompt_payload} <- prompt_payload(session_config, workspace),
         {:ok, command, args, env} <- implementation_command_spec(session_config) do
      {runtime_command, runtime_args} = runtime_command(command, args, workspace)

      {:ok,
       %{
         executable: command,
         args: args,
         runtime_command: runtime_command,
         runtime_args: runtime_args,
         cwd: workspace,
         prompt_payload: prompt_payload,
         env:
           env
           |> Map.merge(%{
             "PREHEN_PROVIDER" => provider,
             "PREHEN_MODEL" => model,
             "PREHEN_PROMPT_PROFILE" => prompt_profile,
             "PREHEN_WORKSPACE" => workspace,
             "PREHEN_PROMPT" => prompt_payload
           })
           |> normalize_env()
       }}
    end
  end

  def build_launch_spec(_session_config), do: {:error, :contract_failed}

  defp build_passthrough_session_config(session_config) do
    with {:ok, launch} <- build_launch_spec(session_config),
         :ok <- ensure_workspace(launch.cwd),
         {:ok, provider} <- fetch_required_string(session_config, :provider, :contract_failed),
         {:ok, model} <- fetch_required_string(session_config, :model, :contract_failed),
         {:ok, prompt_profile} <-
           fetch_required_string(session_config, :prompt_profile, :contract_failed),
         {:ok, profile_name} <-
           fetch_required_string(session_config, :profile_name, :contract_failed) do
      implementation = %Implementation{
        name: implementation_name(session_config),
        command: launch.runtime_command,
        args: launch.runtime_args,
        env: launch.env,
        wrapper: Passthrough
      }

      {:ok,
       %SessionConfig{
         profile_name: profile_name,
         provider: provider,
         model: model,
         prompt_profile: prompt_profile,
         workspace_policy: Map.get(session_config, :workspace_policy),
         implementation: implementation,
         workspace: launch.cwd
       }}
    end
  end

  defp implementation_name(%{implementation: %Implementation{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp implementation_name(%{implementation: implementation}) when is_map(implementation) do
    normalize_optional_string(Map.get(implementation, :name) || Map.get(implementation, "name")) ||
      "pi_coding_agent"
  end

  defp implementation_name(_session_config), do: "pi_coding_agent"

  defp implementation_command_spec(%{implementation: %Implementation{} = implementation}) do
    command = normalize_optional_string(implementation.command)
    args = normalize_args(implementation.args)

    case command do
      nil -> {:error, :launch_failed}
      _command -> {:ok, command, args, normalize_env(implementation.env)}
    end
  end

  defp implementation_command_spec(%{implementation: implementation})
       when is_map(implementation) do
    command =
      normalize_optional_string(
        Map.get(implementation, :command) || Map.get(implementation, "command")
      )

    args = normalize_args(Map.get(implementation, :args) || Map.get(implementation, "args"))
    env = normalize_env(Map.get(implementation, :env) || Map.get(implementation, "env"))

    case command do
      nil -> {:ok, Config.pi_coding_agent_command(), [], env}
      _command -> {:ok, command, args, env}
    end
  end

  defp implementation_command_spec(_session_config) do
    {:ok, Config.pi_coding_agent_command(), [], %{}}
  end

  defp runtime_command(command, args, workspace) do
    {@shell_command,
     ["-lc", "cd \"$1\" && shift && exec \"$@\"", "prehen-pi", workspace, command | args]}
  end

  defp classify_target_resolution(%{executable: executable}) do
    ExecutableHost.resolve_command(executable)
  end

  defp classify_passthrough_support(launch) do
    case ExecutableHost.support_check(%{command: launch.runtime_command}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_root(session_config) do
    case normalize_optional_string(Map.get(session_config, :workspace)) do
      nil ->
        {:error, :capability_failed}

      workspace ->
        if Path.type(workspace) == :absolute do
          {:ok, workspace}
        else
          {:error, :capability_failed}
        end
    end
  end

  defp prompt_payload(session_config, workspace) do
    case normalize_optional_string(Map.get(session_config, :prompt_context)) do
      nil ->
        prompt =
          session_config
          |> normalize_session_config()
          |> PromptContext.build(workspace: %{root_dir: workspace})
          |> Jason.encode!()

        {:ok, prompt}

      prompt ->
        {:ok, prompt}
    end
  end

  defp classify_policy(session_config) do
    mode =
      session_config
      |> Map.get(:workspace_policy, %{})
      |> workspace_policy_mode()

    if mode in @rejected_workspace_policy_modes do
      {:error, :policy_rejected}
    else
      :ok
    end
  end

  defp workspace_policy_mode(policy) when is_map(policy) do
    normalize_optional_string(Map.get(policy, :mode) || Map.get(policy, "mode"))
  end

  defp workspace_policy_mode(_policy), do: nil

  defp fetch_required_string(map, key, error_reason) do
    case normalize_optional_string(Map.get(map, key) || Map.get(map, Atom.to_string(key))) do
      nil -> {:error, error_reason}
      value -> {:ok, value}
    end
  end

  defp normalize_session_config(session_config) do
    %SessionConfig{
      profile_name: Map.get(session_config, :profile_name),
      provider: Map.get(session_config, :provider),
      model: Map.get(session_config, :model),
      prompt_profile: Map.get(session_config, :prompt_profile),
      workspace_policy: Map.get(session_config, :workspace_policy),
      implementation: Map.get(session_config, :implementation),
      workspace: Map.get(session_config, :workspace)
    }
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}

  defp ensure_workspace(workspace) when is_binary(workspace) do
    case File.mkdir_p(workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :capability_failed}
    end
  end
end
