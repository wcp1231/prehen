defmodule Prehen.Config do
  @moduledoc false

  alias Prehen.Workspace.Paths

  @defaults %{
    model: "openai:gpt-5-mini",
    api_key: nil,
    base_url: nil,
    max_steps: 8,
    timeout_ms: 15_000,
    session_status_poll_ms: 50,
    session_idle_ttl_ms: 300_000,
    stm_buffer_limit: 24,
    stm_token_budget: 8_000,
    ltm_adapter_name: :noop,
    ltm_adapter: nil,
    capability_packs: [:local_fs],
    workspace_capability_allowlist: [:local_fs],
    read_max_bytes: 8_192,
    workspace_dir: nil,
    global_dir: nil,
    trace_json: false,
    agent_backend: Prehen.Agent.Backends.JidoAI,
    session_adapter: Prehen.Agent.Session.Adapters.JidoAI,
    retry_policy: Prehen.Agent.Policies.RetryPolicy,
    model_router: Prehen.Agent.Policies.ModelRouter
  }

  @spec load(keyword()) :: map()
  def load(overrides \\ []) do
    workspace_dir = workspace_dir(overrides)
    global_dir = global_dir(overrides)
    ensure_layouts(workspace_dir, global_dir)
    merged_overrides = merge_overrides(overrides, workspace_dir, global_dir)

    %{
      model: env_or_default(merged_overrides, :model, "PREHEN_MODEL"),
      api_key: env_or_default(merged_overrides, :api_key, "PREHEN_API_KEY"),
      base_url: env_or_default(merged_overrides, :base_url, "PREHEN_BASE_URL"),
      max_steps: int_env_or_default(merged_overrides, :max_steps, "PREHEN_MAX_STEPS"),
      timeout_ms: int_env_or_default(merged_overrides, :timeout_ms, "PREHEN_TIMEOUT_MS"),
      session_status_poll_ms:
        int_env_or_default(merged_overrides, :session_status_poll_ms, "PREHEN_STATUS_POLL_MS"),
      session_idle_ttl_ms:
        int_env_or_default(merged_overrides, :session_idle_ttl_ms, "PREHEN_SESSION_IDLE_TTL_MS"),
      stm_buffer_limit:
        int_env_or_default(merged_overrides, :stm_buffer_limit, "PREHEN_STM_BUFFER_LIMIT"),
      stm_token_budget:
        int_env_or_default(merged_overrides, :stm_token_budget, "PREHEN_STM_TOKEN_BUDGET"),
      ltm_adapter_name: atom_config(merged_overrides, :ltm_adapter_name, "PREHEN_LTM_ADAPTER"),
      ltm_adapter: module_config(merged_overrides, :ltm_adapter),
      capability_packs:
        atom_list_config(merged_overrides, :capability_packs, "PREHEN_CAPABILITY_PACKS"),
      workspace_capability_allowlist:
        atom_list_config(
          merged_overrides,
          :workspace_capability_allowlist,
          "PREHEN_WORKSPACE_CAPABILITY_ALLOWLIST"
        ),
      read_max_bytes:
        int_env_or_default(merged_overrides, :read_max_bytes, "PREHEN_READ_MAX_BYTES"),
      workspace_dir: workspace_dir,
      global_dir: global_dir,
      trace_json: bool_env_or_default(merged_overrides, :trace_json, "PREHEN_TRACE_JSON"),
      agent_backend: agent_backend(merged_overrides),
      session_adapter: module_config(merged_overrides, :session_adapter),
      retry_policy: module_config(merged_overrides, :retry_policy),
      model_router: module_config(merged_overrides, :model_router)
    }
  end

  defp env_or_default(overrides, key, env) do
    Keyword.get_lazy(overrides, key, fn ->
      System.get_env(env) || Map.fetch!(@defaults, key)
    end)
  end

  defp int_env_or_default(overrides, key, env) do
    Keyword.get_lazy(overrides, key, fn ->
      case Integer.parse(to_string(System.get_env(env) || Map.fetch!(@defaults, key))) do
        {value, ""} -> value
        _ -> Map.fetch!(@defaults, key)
      end
    end)
  end

  defp bool_env_or_default(overrides, key, env) do
    Keyword.get_lazy(overrides, key, fn ->
      default = Map.fetch!(@defaults, key)

      case String.downcase(to_string(System.get_env(env) || default)) do
        "true" -> true
        "1" -> true
        "false" -> false
        "0" -> false
        _ -> default
      end
    end)
  end

  defp workspace_dir(overrides) do
    overrides
    |> Keyword.get_lazy(:workspace_dir, fn ->
      Keyword.get_lazy(overrides, :workspace, fn ->
        Application.get_env(:prehen, :workspace_dir) ||
          System.get_env("PREHEN_WORKSPACE_DIR") ||
          Paths.default_workspace_dir()
      end)
    end)
    |> to_string()
    |> Path.expand()
  end

  defp global_dir(overrides) do
    overrides
    |> Keyword.get_lazy(:global_dir, fn ->
      Application.get_env(:prehen, :global_dir) ||
        System.get_env("PREHEN_GLOBAL_DIR") ||
        Paths.default_global_dir()
    end)
    |> to_string()
    |> Path.expand()
  end

  defp merge_overrides(overrides, workspace_dir, global_dir) do
    global_overrides =
      global_dir
      |> Path.join("config/runtime.json")
      |> read_runtime_config_file()

    workspace_overrides =
      workspace_dir
      |> Path.join(".prehen/config/runtime.json")
      |> read_runtime_config_file()

    global_overrides
    |> Keyword.merge(workspace_overrides)
    |> Keyword.merge(overrides)
  end

  defp read_runtime_config_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, raw} <- File.read(path),
         {:ok, payload} <- Jason.decode(raw),
         true <- is_map(payload) do
      normalize_runtime_payload(payload)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp normalize_runtime_payload(payload) when is_map(payload) do
    Enum.reduce(payload, [], fn {key, value}, acc ->
      case normalize_runtime_entry(key, value) do
        {k, v} -> Keyword.put(acc, k, v)
        nil -> acc
      end
    end)
  end

  defp normalize_runtime_entry("model", value) when is_binary(value), do: {:model, value}
  defp normalize_runtime_entry("api_key", value) when is_binary(value), do: {:api_key, value}
  defp normalize_runtime_entry("base_url", value) when is_binary(value), do: {:base_url, value}
  defp normalize_runtime_entry("max_steps", value), do: maybe_int_entry(:max_steps, value)
  defp normalize_runtime_entry("timeout_ms", value), do: maybe_int_entry(:timeout_ms, value)

  defp normalize_runtime_entry("session_status_poll_ms", value),
    do: maybe_int_entry(:session_status_poll_ms, value)

  defp normalize_runtime_entry("session_idle_ttl_ms", value),
    do: maybe_int_entry(:session_idle_ttl_ms, value)

  defp normalize_runtime_entry("stm_buffer_limit", value),
    do: maybe_int_entry(:stm_buffer_limit, value)

  defp normalize_runtime_entry("stm_token_budget", value),
    do: maybe_int_entry(:stm_token_budget, value)

  defp normalize_runtime_entry("read_max_bytes", value),
    do: maybe_int_entry(:read_max_bytes, value)

  defp normalize_runtime_entry("trace_json", value), do: maybe_bool_entry(:trace_json, value)

  defp normalize_runtime_entry("workspace_dir", value) when is_binary(value),
    do: {:workspace_dir, value}

  defp normalize_runtime_entry("global_dir", value) when is_binary(value),
    do: {:global_dir, value}

  defp normalize_runtime_entry("ltm_adapter_name", value) when is_binary(value),
    do: {:ltm_adapter_name, to_atom(value)}

  defp normalize_runtime_entry("capability_packs", value) when is_list(value),
    do: {:capability_packs, normalize_atom_list(value)}

  defp normalize_runtime_entry("workspace_capability_allowlist", value) when is_list(value),
    do: {:workspace_capability_allowlist, normalize_atom_list(value)}

  defp normalize_runtime_entry(_, _), do: nil

  defp maybe_int_entry(key, value) when is_integer(value), do: {key, value}

  defp maybe_int_entry(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {key, parsed}
      _ -> nil
    end
  end

  defp maybe_int_entry(_key, _value), do: nil

  defp maybe_bool_entry(key, value) when is_boolean(value), do: {key, value}

  defp maybe_bool_entry(key, value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {key, true}
      "1" -> {key, true}
      "false" -> {key, false}
      "0" -> {key, false}
      _ -> nil
    end
  end

  defp maybe_bool_entry(_key, _value), do: nil

  defp normalize_atom_list(list) do
    list
    |> Enum.map(fn
      value when is_atom(value) -> value
      value when is_binary(value) -> to_atom(value)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp agent_backend(overrides) do
    Keyword.get(
      overrides,
      :agent_backend,
      Application.get_env(:prehen, :agent_backend, Map.fetch!(@defaults, :agent_backend))
    )
  end

  defp module_config(overrides, key) do
    app_default = Application.get_env(:prehen, key)
    override = Keyword.get(overrides, key)

    cond do
      is_atom(override) and not is_nil(override) -> override
      is_atom(app_default) and not is_nil(app_default) -> app_default
      true -> Map.fetch!(@defaults, key)
    end
  end

  defp atom_config(overrides, key, env) do
    app_default = Application.get_env(:prehen, key)
    override = Keyword.get(overrides, key)
    env_value = System.get_env(env)

    cond do
      is_atom(override) and not is_nil(override) ->
        override

      is_binary(env_value) and String.trim(env_value) != "" ->
        to_atom(env_value)

      is_atom(app_default) and not is_nil(app_default) ->
        app_default

      true ->
        Map.fetch!(@defaults, key)
    end
  end

  defp to_atom(value) when is_binary(value) do
    normalized = String.trim(value)

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> String.to_atom(normalized)
    end
  end

  defp atom_list_config(overrides, key, env) do
    app_default = Application.get_env(:prehen, key)
    override = Keyword.get(overrides, key)
    env_value = System.get_env(env)

    cond do
      is_list(override) -> Enum.filter(override, &is_atom/1)
      is_binary(env_value) and String.trim(env_value) != "" -> parse_atom_list(env_value)
      is_list(app_default) -> Enum.filter(app_default, &is_atom/1)
      true -> Map.fetch!(@defaults, key)
    end
  end

  defp parse_atom_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&to_atom/1)
  end

  defp ensure_layouts(workspace_dir, global_dir) do
    _ = Paths.ensure_global_layout(global_dir)
    _ = Paths.ensure_workspace_layout(workspace_dir)
    :ok
  end
end
