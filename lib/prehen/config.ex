defmodule Prehen.Config do
  @moduledoc false

  alias Prehen.Agents.Profile

  @default_timeout_ms 15_000

  @spec load(keyword()) :: map()
  def load(overrides \\ []) do
    %{
      timeout_ms: int_config(overrides, :timeout_ms, "PREHEN_TIMEOUT_MS", @default_timeout_ms),
      trace_json: bool_config(overrides, :trace_json, "PREHEN_TRACE_JSON", false),
      agent_profiles: agent_profiles_config(overrides)
    }
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

  defp agent_profiles_config(overrides) do
    overrides
    |> Keyword.get(:agent_profiles, Application.get_env(:prehen, :agent_profiles, []))
    |> normalize_agent_profiles()
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
        [profile | acc]

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

  defp normalize_profile(attrs) do
    name = fetch_attr(attrs, :name)
    command = fetch_attr(attrs, :command)

    with true <- is_binary(name) and String.trim(name) != "",
         {:ok, normalized_command, args} <- normalize_command(command, fetch_attr(attrs, :args)) do
      {:ok,
       %Profile{
         name: String.trim(name),
         command: normalized_command,
         args: args,
         env: normalize_env(fetch_attr(attrs, :env)),
         transport: normalize_transport(fetch_attr(attrs, :transport)),
         metadata: normalize_metadata(fetch_attr(attrs, :metadata))
       }}
    else
      _ -> :error
    end
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_command([command | args], _extra_args) when is_binary(command) do
    {:ok, [command | Enum.map(args, &to_string/1)], []}
  end

  defp normalize_command(command, args) when is_binary(command) do
    {:ok, command, Enum.map(List.wrap(args), &to_string/1)}
  end

  defp normalize_command(_command, _args), do: :error

  defp normalize_env(env) when is_map(env), do: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  defp normalize_env(_env), do: %{}

  defp normalize_transport(nil), do: :stdio
  defp normalize_transport(:stdio), do: :stdio
  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport(module) when is_atom(module), do: module
  defp normalize_transport(_transport), do: :stdio

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
