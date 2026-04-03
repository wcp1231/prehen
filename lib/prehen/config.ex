defmodule Prehen.Config do
  @moduledoc false

  require Logger

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.UserConfig

  @default_timeout_ms 15_000
  @default_pi_coding_agent_command "pi-coding-agent"
  @default_workspace_policy %{mode: "scoped"}

  @spec load(keyword()) :: map()
  def load(overrides \\ []) do
    %{
      timeout_ms: int_config(overrides, :timeout_ms, "PREHEN_TIMEOUT_MS", @default_timeout_ms),
      trace_json: bool_config(overrides, :trace_json, "PREHEN_TRACE_JSON", false),
      agent_profiles: agent_profiles_config(overrides),
      agent_implementations: agent_implementations_config(overrides)
    }
  end

  def resolve_session_config!(config, opts \\ []) do
    profile = resolve_profile!(Map.get(config, :agent_profiles, []), opts)

    implementation =
      resolve_implementation!(Map.get(config, :agent_implementations, []), profile.implementation)

    %SessionConfig{
      profile_name: profile.name,
      provider:
        normalize_optional_string(Keyword.get(opts, :provider)) || profile.default_provider,
      model: normalize_optional_string(Keyword.get(opts, :model)) || profile.default_model,
      prompt_profile:
        normalize_optional_string(Keyword.get(opts, :prompt_profile)) || profile.prompt_profile,
      workspace_policy: profile.workspace_policy,
      implementation: implementation
    }
  end

  def pi_coding_agent_command do
    normalize_optional_string(System.get_env("PI_CODING_AGENT_BIN")) ||
      @default_pi_coding_agent_command
  end

  defp int_config(overrides, key, env_var, default) do
    case Keyword.get(overrides, key) do
      value when is_integer(value) ->
        value

      _ ->
        case System.get_env(env_var) do
          nil -> default
          value -> parse_int(value, default)
        end
    end
  end

  defp bool_config(overrides, key, env_var, default) do
    case Keyword.get(overrides, key) do
      value when is_boolean(value) ->
        value

      _ ->
        case System.get_env(env_var) do
          nil -> default
          value -> parse_bool(value, default)
        end
    end
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp parse_bool(value, _default) when value in ["1", "true", "TRUE", "yes", "YES"], do: true
  defp parse_bool(value, _default) when value in ["0", "false", "FALSE", "no", "NO"], do: false
  defp parse_bool(_value, default), do: default

  defp load_user_config(overrides) do
    if Keyword.has_key?(overrides, :user_config) do
      overrides
      |> Keyword.fetch!(:user_config)
      |> UserConfig.normalize()
    else
      opts =
        case Keyword.get(overrides, :prehen_home) do
          nil -> []
          root -> [root: root]
        end

      case UserConfig.load(opts) do
        {:ok, user_config} ->
          user_config

        {:error, %YamlElixir.FileNotFoundError{}} ->
          UserConfig.empty()

        {:error, reason} ->
          Logger.warning("Failed to load Prehen user config: #{format_error(reason)}")
          UserConfig.empty()
      end
    end
  end

  defp agent_profiles_config(overrides) do
    if Keyword.has_key?(overrides, :agent_profiles) do
      overrides
      |> Keyword.fetch!(:agent_profiles)
      |> normalize_agent_profiles()
    else
      user_config = load_user_config(overrides)

      user_config
      |> Map.get(:profiles, [])
      |> bridge_user_profiles()
      |> normalize_agent_profiles()
    end
  end

  defp agent_implementations_config(overrides) do
    overrides
    |> Keyword.get(
      :agent_implementations,
      Application.get_env(:prehen, :agent_implementations, [])
    )
    |> normalize_agent_implementations()
  end

  defp normalize_agent_profiles(%{} = profiles) do
    profiles
    |> Enum.map(fn {name, attrs} ->
      attrs
      |> Map.new()
      |> Map.put_new(:name, name)
    end)
    |> normalize_agent_profiles()
  end

  defp normalize_agent_profiles(profiles) when is_list(profiles) do
    profiles
    |> Enum.reduce([], fn
      %Profile{} = profile, acc ->
        case normalize_profile(Map.from_struct(profile)) do
          {:ok, normalized_profile} -> [normalized_profile | acc]
          :error -> acc
        end

      attrs, acc when is_map(attrs) ->
        case normalize_profile(attrs) do
          {:ok, profile} -> [profile | acc]
          :error -> acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_agent_profiles(_profiles), do: []

  defp bridge_user_profiles(profiles) when is_list(profiles) do
    Enum.reduce(profiles, [], fn profile, acc ->
      case bridge_user_profile(profile) do
        {:ok, bridged_profile} ->
          [bridged_profile | acc]

        {:drop, reason} ->
          log_dropped_user_profile(profile, reason)
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp bridge_user_profiles(_profiles), do: []

  defp bridge_user_profile(profile) when is_map(profile) do
    with :ok <- enabled_profile(profile),
         {:ok, name} <- required_user_string(profile, :id),
         {:ok, label} <- required_user_string(profile, :label),
         {:ok, implementation} <- user_runtime_implementation(profile),
         {:ok, default_provider} <- required_user_string(profile, :default_provider),
         {:ok, default_model} <- required_user_string(profile, :default_model) do
      {:ok,
       %{
         name: name,
         label: label,
         description: normalize_optional_string(fetch_attr(profile, :description)),
         implementation: implementation,
         default_provider: default_provider,
         default_model: default_model,
         prompt_profile: default_prompt_profile(name),
         workspace_policy: @default_workspace_policy
       }}
    else
      {:error, reason} -> {:drop, reason}
    end
  end

  defp bridge_user_profile(_profile), do: {:drop, :invalid_profile}

  defp normalize_agent_implementations(%{} = implementations) do
    implementations
    |> Enum.map(fn {name, attrs} ->
      attrs
      |> Map.new()
      |> Map.put_new(:name, name)
    end)
    |> normalize_agent_implementations()
  end

  defp normalize_agent_implementations(implementations) when is_list(implementations) do
    implementations
    |> Enum.reduce([], fn
      %Implementation{} = implementation, acc ->
        case normalize_implementation(Map.from_struct(implementation)) do
          {:ok, normalized_implementation} -> [normalized_implementation | acc]
          :error -> acc
        end

      attrs, acc when is_map(attrs) ->
        case normalize_implementation(attrs) do
          {:ok, implementation} -> [implementation | acc]
          :error -> acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_agent_implementations(_implementations), do: []

  defp normalize_profile(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, label} <- required_string(attrs, :label),
         {:ok, implementation} <- required_string(attrs, :implementation),
         {:ok, default_provider} <- required_string(attrs, :default_provider),
         {:ok, default_model} <- required_string(attrs, :default_model),
         {:ok, prompt_profile} <- required_string(attrs, :prompt_profile),
         {:ok, workspace_policy} <- required_map(attrs, :workspace_policy) do
      {:ok,
       %Profile{
         name: name,
         label: label,
         description: normalize_optional_string(fetch_attr(attrs, :description)),
         implementation: implementation,
         default_provider: default_provider,
         default_model: default_model,
         prompt_profile: prompt_profile,
         workspace_policy: workspace_policy,
         command: normalize_optional_command(fetch_attr(attrs, :command)),
         args: normalize_args(fetch_attr(attrs, :args)),
         env: normalize_env(fetch_attr(attrs, :env)),
         transport: normalize_transport(fetch_attr(attrs, :transport)),
         wrapper: normalize_wrapper(fetch_attr(attrs, :wrapper)),
         metadata: normalize_metadata(fetch_attr(attrs, :metadata))
       }}
    else
      _ -> :error
    end
  end

  defp normalize_implementation(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, command} <- required_string(attrs, :command),
         {:ok, args} <- required_args(attrs, :args),
         {:ok, wrapper} <- required_wrapper(attrs, :wrapper) do
      {:ok,
       %Implementation{
         name: name,
         command: command,
         args: args,
         env: normalize_env(fetch_attr(attrs, :env)),
         wrapper: wrapper
       }}
    else
      _ -> :error
    end
  end

  defp fetch_attr(attrs, key) do
    if Map.has_key?(attrs, key) do
      Map.get(attrs, key)
    else
      Map.get(attrs, Atom.to_string(key))
    end
  end

  defp required_string(attrs, key) do
    case normalize_optional_string(fetch_attr(attrs, key)) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp required_map(attrs, key) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp required_args(attrs, key) do
    case fetch_attr(attrs, key) do
      args when is_list(args) -> {:ok, Enum.map(args, &to_string/1)}
      _ -> :error
    end
  end

  defp required_wrapper(attrs, key) do
    case normalize_wrapper(fetch_attr(attrs, key)) do
      nil -> :error
      wrapper -> {:ok, wrapper}
    end
  end

  defp required_user_string(attrs, key) do
    case normalize_optional_string(fetch_attr(attrs, key)) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp user_runtime_implementation(profile) do
    case normalize_optional_string(fetch_attr(profile, :runtime)) do
      "pi" -> {:ok, "pi_coding_agent"}
      runtime -> {:error, {:unsupported_runtime, runtime}}
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp default_prompt_profile(name), do: "#{name}_default"

  defp enabled_profile(profile) do
    if normalize_enabled(fetch_attr(profile, :enabled)) do
      :ok
    else
      {:error, :disabled}
    end
  end

  defp normalize_enabled(value) when value in [true, false], do: value
  defp normalize_enabled(value) when value in ["true", "TRUE", "yes", "YES", "1"], do: true
  defp normalize_enabled(value) when value in ["false", "FALSE", "no", "NO", "0"], do: false
  defp normalize_enabled(_value), do: true

  defp log_dropped_user_profile(_profile, :disabled), do: :ok

  defp log_dropped_user_profile(profile, reason) do
    Logger.warning(
      "Dropped user profile #{inspect(user_profile_ref(profile))}: #{format_drop_reason(reason)}"
    )
  end

  defp user_profile_ref(profile) do
    normalize_optional_string(fetch_attr(profile, :id)) ||
      normalize_optional_string(fetch_attr(profile, :label)) ||
      "<unknown>"
  end

  defp format_drop_reason(:disabled), do: "disabled"
  defp format_drop_reason(:invalid_profile), do: "invalid profile"
  defp format_drop_reason({:missing_field, key}), do: "missing required field #{key}"

  defp format_drop_reason({:unsupported_runtime, runtime}),
    do: "unsupported runtime #{inspect(runtime)}"

  defp format_drop_reason(other), do: inspect(other)

  defp format_error(%_{} = error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  defp resolve_implementation!(implementations, implementation_name) do
    Enum.find(implementations, fn
      %Implementation{name: ^implementation_name} -> true
      _implementation -> false
    end) || raise KeyError, key: implementation_name, term: implementations
  end

  defp normalize_optional_command([command | args]) when is_binary(command) do
    [command | Enum.map(args, &to_string/1)]
  end

  defp normalize_optional_command(command) when is_binary(command), do: command
  defp normalize_optional_command(_command), do: nil

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp normalize_env(env) when is_map(env),
    do: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp normalize_env(_env), do: %{}

  defp normalize_transport(nil), do: :stdio
  defp normalize_transport(:stdio), do: :stdio
  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport(module) when is_atom(module), do: module
  defp normalize_transport(_transport), do: :stdio

  defp normalize_wrapper(wrapper) when is_atom(wrapper), do: wrapper
  defp normalize_wrapper(_wrapper), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp resolve_profile!(profiles, opts) do
    case normalize_optional_string(Keyword.get(opts, :agent) || Keyword.get(opts, :agent_name)) do
      nil ->
        List.first(profiles) || raise KeyError, key: :agent, term: profiles

      agent_name ->
        Enum.find(profiles, &(&1.name == agent_name)) ||
          raise KeyError, key: agent_name, term: profiles
    end
  end
end
