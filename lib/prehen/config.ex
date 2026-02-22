defmodule Prehen.Config do
  @moduledoc false

  alias Prehen.Config.Structured
  alias Prehen.Workspace.Paths

  @defaults %{
    agent: nil,
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
    system_prompt: nil,
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

    structured = Structured.load(workspace_dir, global_dir)

    merged_overrides =
      structured.runtime
      |> normalize_runtime_payload()
      |> Keyword.merge(overrides)

    initial_config_error = normalize_structured_error(Structured.first_error(structured))

    {resolved_agent, config_error} =
      resolve_agent_template(structured, merged_overrides, initial_config_error)

    explicit_capability_packs? = Keyword.has_key?(overrides, :capability_packs)

    {model_candidates, model, api_key, base_url, model_params} =
      resolve_modeling(merged_overrides, resolved_agent)

    capability_packs =
      cond do
        explicit_capability_packs? ->
          normalize_pack_override(Keyword.get(overrides, :capability_packs))

        is_map(resolved_agent) and resolved_agent.capability_packs != [] ->
          resolved_agent.capability_packs

        true ->
          atom_list_config(merged_overrides, :capability_packs, "PREHEN_CAPABILITY_PACKS")
      end

    %{
      agent:
        if(is_map(resolved_agent),
          do: resolved_agent.agent,
          else: normalize_optional_binary(Keyword.get(merged_overrides, :agent))
        ),
      model: model,
      api_key: api_key,
      base_url: base_url,
      model_params: model_params,
      model_candidates: model_candidates,
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
      capability_packs: capability_packs,
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
      system_prompt:
        if(is_map(resolved_agent),
          do: resolved_agent.system_prompt,
          else: normalize_optional_binary(Keyword.get(merged_overrides, :system_prompt))
        ),
      agent_template: resolved_agent,
      structured_config: structured,
      config_error: config_error,
      agent_backend: agent_backend(merged_overrides),
      session_adapter: module_config(merged_overrides, :session_adapter),
      retry_policy: module_config(merged_overrides, :retry_policy),
      model_router: module_config(merged_overrides, :model_router)
    }
  end

  defp resolve_modeling(merged_overrides, resolved_agent) do
    if is_map(resolved_agent) and is_list(resolved_agent.model_candidates) and
         resolved_agent.model_candidates != [] do
      primary = hd(resolved_agent.model_candidates)
      request_opts = primary.request_opts || []

      {
        resolved_agent.model_candidates,
        primary.model,
        optional_binary(Keyword.get(request_opts, :api_key)),
        optional_binary(Keyword.get(request_opts, :base_url)),
        Map.get(primary, :params, %{})
      }
    else
      model =
        normalize_model_spec(Keyword.get(merged_overrides, :model, Map.fetch!(@defaults, :model)))

      api_key = optional_binary(Keyword.get(merged_overrides, :api_key))
      base_url = optional_binary(Keyword.get(merged_overrides, :base_url))
      model_params = normalize_call_model_params(merged_overrides)

      provider_options =
        normalize_provider_options(Keyword.get(merged_overrides, :provider_options))

      runtime_candidate = %{
        provider_ref: "__runtime__",
        provider: provider_from_model(model),
        model_id: model_id_from_model(model),
        model_name: model_id_from_model(model),
        model: model,
        params: model_params,
        request_opts:
          []
          |> put_if_present(:api_key, api_key)
          |> put_if_present(:base_url, base_url)
          |> maybe_put_provider_options(provider_options),
        on_errors: []
      }

      {[runtime_candidate], model, api_key, base_url, model_params}
    end
  end

  defp resolve_agent_template(_structured, _merged_overrides, config_error)
       when not is_nil(config_error) do
    {nil, config_error}
  end

  defp resolve_agent_template(structured, merged_overrides, nil) do
    agent_name = normalize_optional_binary(Keyword.get(merged_overrides, :agent))

    if is_nil(agent_name) do
      {nil, nil}
    else
      case Structured.resolve_agent(structured, agent_name, merged_overrides) do
        {:ok, resolved} ->
          {resolved, nil}

        {:error, reason} ->
          {nil, normalize_agent_resolve_error(reason)}
      end
    end
  end

  defp normalize_structured_error(nil), do: nil

  defp normalize_structured_error(%{} = error) do
    %{
      code: error.code,
      message: error.message,
      file: error.file,
      path: error.path,
      detail: error.detail
    }
  end

  defp normalize_agent_resolve_error({:agent_template_not_found, agent_name}) do
    %{
      code: :agent_template_not_found,
      message: "agent template not found: #{agent_name}",
      detail: %{agent: agent_name}
    }
  end

  defp normalize_agent_resolve_error({:secret_ref_not_found, ref}) do
    %{
      code: :secret_ref_not_found,
      message: "secret_ref not found: #{ref}",
      detail: %{secret_ref: ref}
    }
  end

  defp normalize_agent_resolve_error({:secret_value_invalid, ref}) do
    %{
      code: :secret_value_invalid,
      message: "secret_ref value must be a non-empty string: #{ref}",
      detail: %{secret_ref: ref}
    }
  end

  defp normalize_agent_resolve_error({:provider_credentials_missing, provider_ref}) do
    %{
      code: :provider_credentials_missing,
      message: "provider credentials missing: #{provider_ref}",
      detail: %{provider_ref: provider_ref}
    }
  end

  defp normalize_agent_resolve_error({:provider_endpoint_missing, provider_ref}) do
    %{
      code: :provider_endpoint_missing,
      message: "provider endpoint missing: #{provider_ref}",
      detail: %{provider_ref: provider_ref}
    }
  end

  defp normalize_agent_resolve_error({:provider_not_found, provider_ref}) do
    %{
      code: :provider_not_found,
      message: "provider not found: #{provider_ref}",
      detail: %{provider_ref: provider_ref}
    }
  end

  defp normalize_agent_resolve_error({:provider_model_not_found, provider_ref, model_id}) do
    %{
      code: :provider_model_not_found,
      message: "provider model not found: #{provider_ref}/#{model_id}",
      detail: %{provider_ref: provider_ref, model_id: model_id}
    }
  end

  defp normalize_agent_resolve_error(reason) do
    %{
      code: :agent_template_invalid,
      message: "failed to resolve agent template",
      detail: reason
    }
  end

  defp normalize_runtime_payload(payload) when is_map(payload) do
    Enum.reduce(payload, [], fn {key, value}, acc ->
      case normalize_runtime_entry(key, value) do
        {k, v} -> Keyword.put(acc, k, v)
        nil -> acc
      end
    end)
  end

  defp normalize_runtime_payload(_payload), do: []

  defp normalize_runtime_entry("agent", value) when is_binary(value), do: {:agent, value}
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

  defp normalize_runtime_entry("system_prompt", value) when is_binary(value),
    do: {:system_prompt, value}

  defp normalize_runtime_entry("provider_options", value) when is_map(value),
    do: {:provider_options, value}

  defp normalize_runtime_entry("model_params", value) when is_map(value),
    do: {:model_params, value}

  defp normalize_runtime_entry("temperature", value) do
    case normalize_temperature(value) do
      nil -> nil
      parsed -> {:temperature, parsed}
    end
  end

  defp normalize_runtime_entry("max_tokens", value), do: maybe_int_entry(:max_tokens, value)
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

  defp normalize_temperature(value) when is_integer(value), do: value * 1.0
  defp normalize_temperature(value) when is_float(value), do: value

  defp normalize_temperature(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_temperature(_), do: nil

  defp normalize_call_model_params(overrides) when is_list(overrides) do
    normalize_call_model_params(Map.new(overrides))
  end

  defp normalize_call_model_params(%{} = overrides) do
    model_params =
      overrides
      |> Map.get(:model_params, Map.get(overrides, "model_params", %{}))
      |> normalize_params_map()

    extra =
      %{}
      |> maybe_put_param(:temperature, Map.get(overrides, :temperature))
      |> maybe_put_param(:temperature, Map.get(overrides, "temperature"))
      |> maybe_put_param(:max_tokens, Map.get(overrides, :max_tokens))
      |> maybe_put_param(:max_tokens, Map.get(overrides, "max_tokens"))
      |> normalize_params_map()

    Map.merge(model_params, extra)
  end

  defp normalize_call_model_params(_), do: %{}

  defp normalize_params_map(nil), do: %{}

  defp normalize_params_map(%{} = params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      normalized_key =
        key
        |> to_string()
        |> String.trim()
        |> String.downcase()

      case {normalized_key, value} do
        {"temperature", val} ->
          case normalize_temperature(val) do
            nil -> acc
            parsed -> Map.put(acc, :temperature, parsed)
          end

        {"max_tokens", val} when is_integer(val) ->
          Map.put(acc, :max_tokens, val)

        {"max_tokens", val} when is_binary(val) ->
          case Integer.parse(String.trim(val)) do
            {parsed, ""} -> Map.put(acc, :max_tokens, parsed)
            _ -> acc
          end

        {_other, _value} ->
          Map.put(acc, to_atom_key(normalized_key), value)
      end
    end)
  end

  defp normalize_params_map(_), do: %{}

  defp maybe_put_param(acc, _key, nil), do: acc
  defp maybe_put_param(acc, key, value), do: Map.put(acc, key, value)

  defp normalize_provider_options(%{} = provider_options), do: provider_options
  defp normalize_provider_options(_), do: nil

  defp maybe_put_provider_options(opts, nil), do: opts

  defp maybe_put_provider_options(opts, %{} = provider_options) do
    keyword =
      Enum.map(provider_options, fn {key, value} ->
        {to_atom_key(key), value}
      end)

    Keyword.put(opts, :provider_options, keyword)
  end

  defp normalize_pack_override(value) when is_list(value), do: normalize_atom_list(value)
  defp normalize_pack_override(_), do: []

  defp optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_binary(_), do: nil

  defp normalize_optional_binary(value) when is_binary(value), do: optional_binary(value)
  defp normalize_optional_binary(_), do: nil

  defp normalize_model_spec(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" ->
        Map.fetch!(@defaults, :model)

      String.contains?(normalized, ":") ->
        normalized

      true ->
        "openai:#{normalized}"
    end
  end

  defp normalize_model_spec(_), do: Map.fetch!(@defaults, :model)

  defp provider_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _id] when provider != "" -> provider
      _ -> "openai"
    end
  end

  defp provider_from_model(_), do: "openai"

  defp model_id_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, model_id] when model_id != "" -> model_id
      _ -> model
    end
  end

  defp model_id_from_model(_), do: "gpt-5-mini"

  defp put_if_present(list, _key, nil), do: list
  defp put_if_present(list, _key, ""), do: list
  defp put_if_present(list, key, value), do: Keyword.put(list, key, value)

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

  defp to_atom_key(value) when is_atom(value), do: value
  defp to_atom_key(value) when is_binary(value), do: to_atom(value)
  defp to_atom_key(value), do: value |> to_string() |> to_atom_key()

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

  defp ensure_layouts(workspace_dir, global_dir) do
    _ = Paths.ensure_global_layout(global_dir)
    _ = Paths.ensure_workspace_layout(workspace_dir)
    :ok
  end
end
