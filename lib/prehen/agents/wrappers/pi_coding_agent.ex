defmodule Prehen.Agents.Wrappers.PiCodingAgent do
  @moduledoc false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Agents.Wrappers.Passthrough
  alias Prehen.Config

  @behaviour Wrapper

  @support_probe_gateway_session_id "gw_pi_support_probe"
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
         {:ok, wrapper} <- start_link(session_config: session_config) do
      Process.unlink(wrapper)

      try do
        run_runtime_probe(wrapper, probe_open_session_attrs(session_config, launch))
      after
        maybe_stop_wrapper(wrapper)
      end
    else
      {:error, reason} -> classify_preflight_error(reason)
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

  defp probe_open_session_attrs(session_config, launch) do
    %{
      gateway_session_id: @support_probe_gateway_session_id,
      agent: Map.get(session_config, :profile_name),
      profile_name: Map.get(session_config, :profile_name),
      provider: Map.get(session_config, :provider),
      model: Map.get(session_config, :model),
      prompt_profile: Map.get(session_config, :prompt_profile),
      workspace: launch.cwd,
      prompt: decode_probe_prompt(launch.prompt_payload)
    }
  end

  defp decode_probe_prompt(prompt_payload) when is_binary(prompt_payload) do
    case Jason.decode(prompt_payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"system" => prompt_payload}
    end
  end

  defp run_runtime_probe(wrapper, attrs) do
    try do
      wrapper
      |> open_session(attrs)
      |> classify_runtime_probe_result()
    catch
      :exit, {:timeout, {GenServer, :call, _call}} ->
        {:error, :contract_failed}

      :exit, reason ->
        classify_runtime_probe_result({:error, reason})
    end
  end

  defp classify_runtime_probe_result({:ok, opened}) do
    case fetch_agent_session_id(opened) do
      {:ok, _agent_session_id} -> :ok
      :error -> {:error, :contract_failed}
    end
  end

  defp classify_runtime_probe_result({:error, reason}) do
    case reason do
      :timeout -> {:error, :contract_failed}
      :normal -> {:error, :contract_failed}
      :shutdown -> {:error, :contract_failed}
      :missing_gateway_session_id -> {:error, :contract_failed}
      :session_already_open -> {:error, :contract_failed}
      :session_already_opening -> {:error, :contract_failed}
      :session_not_open -> {:error, :contract_failed}
      {:exit_status, _status} -> {:error, :contract_failed}
      {:shutdown, _detail} -> {:error, :contract_failed}
      {:missing_required_field, _key} -> {:error, :contract_failed}
      {:timeout, _detail} -> {:error, :contract_failed}
      _other -> {:error, :contract_failed}
    end
  end

  defp classify_runtime_probe_result(_other), do: {:error, :contract_failed}

  defp classify_preflight_error(reason)
       when reason in [:capability_failed, :contract_failed, :policy_rejected],
       do: {:error, reason}

  defp classify_preflight_error(_reason), do: {:error, :launch_failed}

  defp fetch_agent_session_id(%{agent_session_id: agent_session_id})
       when is_binary(agent_session_id) and agent_session_id != "",
       do: {:ok, agent_session_id}

  defp fetch_agent_session_id(%{"agent_session_id" => agent_session_id})
       when is_binary(agent_session_id) and agent_session_id != "",
       do: {:ok, agent_session_id}

  defp fetch_agent_session_id(%{payload: payload}) when is_map(payload),
    do: fetch_agent_session_id(payload)

  defp fetch_agent_session_id(%{"payload" => payload}) when is_map(payload),
    do: fetch_agent_session_id(payload)

  defp fetch_agent_session_id(_opened), do: :error

  defp maybe_stop_wrapper(wrapper) when is_pid(wrapper) do
    if Process.alive?(wrapper) do
      try do
        stop(wrapper)
        :ok
      rescue
        _error -> :ok
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_stop_wrapper(_wrapper), do: :ok
end
