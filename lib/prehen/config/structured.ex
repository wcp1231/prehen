defmodule Prehen.Config.Structured do
  @moduledoc false

  alias Prehen.Workspace.Paths

  @type error_t :: %{
          code: atom(),
          message: String.t(),
          file: String.t() | nil,
          path: String.t() | nil,
          detail: term()
        }

  @type source_t :: %{
          workspace: String.t() | nil,
          global: String.t() | nil
        }

  @type loaded_t :: %{
          providers: map(),
          agents: map(),
          runtime: map(),
          secrets: map(),
          sources: %{
            providers: source_t(),
            agents: source_t(),
            runtime: source_t(),
            secrets: source_t()
          },
          errors: [error_t()]
        }

  @default_fallback_errors [:timeout, :rate_limit, :provider_error]

  @spec load(String.t(), String.t()) :: loaded_t()
  def load(workspace_dir, global_dir) when is_binary(workspace_dir) and is_binary(global_dir) do
    _ = Application.ensure_all_started(:yaml_elixir)

    global_scope = load_scope(Paths.global_config_dir(global_dir), :global)
    workspace_scope = load_scope(Paths.config_dir(workspace_dir), :workspace)

    providers = deep_merge_maps(global_scope.providers, workspace_scope.providers)
    agents = deep_merge_maps(global_scope.agents, workspace_scope.agents)
    runtime = deep_merge_maps(global_scope.runtime, workspace_scope.runtime)
    secrets = deep_merge_maps(global_scope.secrets, workspace_scope.secrets)

    errors =
      global_scope.errors ++
        workspace_scope.errors ++
        validate_providers(providers) ++
        validate_agents(agents)

    %{
      providers: providers,
      agents: agents,
      runtime: runtime,
      secrets: secrets,
      sources: %{
        providers:
          merge_sources(global_scope.sources.providers, workspace_scope.sources.providers),
        agents: merge_sources(global_scope.sources.agents, workspace_scope.sources.agents),
        runtime: merge_sources(global_scope.sources.runtime, workspace_scope.sources.runtime),
        secrets: merge_sources(global_scope.sources.secrets, workspace_scope.sources.secrets)
      },
      errors: errors
    }
  end

  @spec resolve_agent(loaded_t(), String.t(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def resolve_agent(%{} = loaded, agent_name, call_overrides \\ []) when is_binary(agent_name) do
    normalized_name = String.trim(agent_name)
    call_params = normalize_call_model_params(call_overrides)

    with {:ok, agent} <- fetch_agent(loaded.agents, normalized_name),
         {:ok, primary} <-
           resolve_candidate(agent["model"], loaded, normalized_name, call_params, primary?: true),
         {:ok, fallbacks} <-
           resolve_fallbacks(agent["fallback_models"], loaded, normalized_name, call_params),
         {:ok, capability_packs} <-
           normalize_capability_packs(agent["capability_packs"], normalized_name) do
      {:ok,
       %{
         agent: normalized_name,
         name: normalize_optional_binary(agent["name"]) || normalized_name,
         description: normalize_optional_binary(agent["description"]) || "",
         system_prompt: normalize_optional_binary(agent["system_prompt"]),
         capability_packs: capability_packs,
         model_candidates: [primary | fallbacks]
       }}
    end
  end

  @spec first_error(loaded_t()) :: error_t() | nil
  def first_error(%{errors: [first | _]}), do: first
  def first_error(_), do: nil

  defp load_scope(config_dir, scope) when is_binary(config_dir) do
    providers_path = Path.join(config_dir, "providers.yaml")
    agents_path = Path.join(config_dir, "agents.yaml")
    runtime_yaml_path = Path.join(config_dir, "runtime.yaml")
    runtime_json_path = Path.join(config_dir, "runtime.json")
    secrets_path = Path.join(config_dir, "secrets.yaml")

    {providers_doc, providers_errors, providers_source} = read_yaml_file(providers_path)
    {agents_doc, agents_errors, agents_source} = read_yaml_file(agents_path)

    {runtime_yaml_doc, runtime_yaml_errors, runtime_yaml_source} =
      read_yaml_file(runtime_yaml_path)

    {runtime_json_doc, runtime_json_errors, runtime_json_source} =
      read_json_file(runtime_json_path)

    {secrets_doc, secrets_errors, secrets_source} = read_yaml_file(secrets_path)

    {providers, providers_schema_errors} =
      extract_map_section(providers_doc, "providers", providers_source)

    {agents, agents_schema_errors} =
      extract_map_section(agents_doc, "agents", agents_source)

    {runtime_yaml, runtime_yaml_schema_errors} =
      extract_map_section(runtime_yaml_doc, "runtime", runtime_yaml_source)

    {runtime_json, runtime_json_schema_errors} =
      extract_map_section(runtime_json_doc, "runtime", runtime_json_source)

    {secrets, secrets_schema_errors} =
      extract_map_section(secrets_doc, "secrets", secrets_source)

    runtime = deep_merge_maps(runtime_json, runtime_yaml)

    runtime_source = pick_runtime_source(runtime_yaml_source, runtime_json_source)

    %{
      providers: providers,
      agents: agents,
      runtime: runtime,
      secrets: secrets,
      sources: %{
        providers: source_for_scope(scope, providers_source),
        agents: source_for_scope(scope, agents_source),
        runtime: source_for_scope(scope, runtime_source),
        secrets: source_for_scope(scope, secrets_source)
      },
      errors:
        providers_errors ++
          agents_errors ++
          runtime_yaml_errors ++
          runtime_json_errors ++
          secrets_errors ++
          providers_schema_errors ++
          agents_schema_errors ++
          runtime_yaml_schema_errors ++
          runtime_json_schema_errors ++
          secrets_schema_errors
    }
  end

  defp source_for_scope(:workspace, source_path) do
    %{workspace: source_path, global: nil}
  end

  defp source_for_scope(:global, source_path) do
    %{workspace: nil, global: source_path}
  end

  defp merge_sources(%{} = global, %{} = workspace) do
    %{
      workspace: workspace.workspace,
      global: global.global
    }
  end

  defp pick_runtime_source(nil, nil), do: nil
  defp pick_runtime_source(source, nil), do: source
  defp pick_runtime_source(nil, source), do: source
  defp pick_runtime_source(source, _other), do: source

  defp read_yaml_file(path) when is_binary(path) do
    if File.regular?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, payload} ->
          {normalize_loaded_payload(payload), [], path}

        {:error, reason} ->
          {%{},
           [
             error(
               :config_parse_error,
               "failed to parse yaml file",
               file: path,
               detail: format_parse_reason(reason)
             )
           ], path}
      end
    else
      {%{}, [], nil}
    end
  rescue
    error ->
      {%{},
       [
         error(
           :config_parse_error,
           "failed to parse yaml file",
           file: path,
           detail: Exception.message(error)
         )
       ], path}
  end

  defp read_json_file(path) when is_binary(path) do
    if File.regular?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, payload} <- Jason.decode(raw),
           true <- is_map(payload) do
        {normalize_loaded_payload(payload), [], path}
      else
        _ ->
          {%{},
           [
             error(
               :config_parse_error,
               "failed to parse json file",
               file: path,
               detail: :invalid_json
             )
           ], path}
      end
    else
      {%{}, [], nil}
    end
  rescue
    _ ->
      {%{},
       [
         error(
           :config_parse_error,
           "failed to parse json file",
           file: path,
           detail: :invalid_json
         )
       ], path}
  end

  defp extract_map_section(%{} = payload, section, file) when is_binary(section) do
    cond do
      is_map(payload[section]) ->
        {payload[section], []}

      Map.has_key?(payload, section) ->
        {%{},
         [
           error(
             :config_schema_invalid,
             "#{section} section must be a map",
             file: file,
             path: section,
             detail: type_of(payload[section])
           )
         ]}

      true ->
        {payload, []}
    end
  end

  defp extract_map_section(_payload, section, file) do
    {%{},
     [
       error(
         :config_schema_invalid,
         "#{section} section must be a map",
         file: file,
         path: section,
         detail: :invalid_type
       )
     ]}
  end

  defp normalize_loaded_payload(payload) when is_list(payload) do
    case payload do
      [%{} = first | _] -> normalize_loaded_payload(first)
      _ -> %{}
    end
  end

  defp normalize_loaded_payload(%{} = payload), do: stringify_keys(payload)
  defp normalize_loaded_payload(_), do: %{}

  defp stringify_keys(%{} = map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, stringify_key(key), stringify_keys(value))
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)

  defp deep_merge_maps(%{} = left, %{} = right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge_maps(l, r), else: r
    end)
  end

  defp deep_merge_maps(_left, %{} = right), do: right
  defp deep_merge_maps(%{} = left, _right), do: left
  defp deep_merge_maps(_left, _right), do: %{}

  defp validate_providers(providers) when is_map(providers) do
    Enum.flat_map(providers, fn {provider_ref, provider_cfg} ->
      validate_provider(provider_ref, provider_cfg)
    end)
  end

  defp validate_provider(provider_ref, provider_cfg) when is_map(provider_cfg) do
    ref_path = "providers.#{provider_ref}"
    kind = normalize_optional_binary(provider_cfg["kind"])
    provider_name = normalize_optional_binary(provider_cfg["provider"])
    endpoint = normalize_optional_binary(provider_cfg["endpoint"])
    models = provider_cfg["models"]

    []
    |> maybe_error(
      is_nil(kind),
      :provider_kind_invalid,
      "provider kind is required",
      ref_path <> ".kind"
    )
    |> maybe_error(
      not is_nil(kind) and kind not in ["official", "openai_compatible"],
      :provider_kind_invalid,
      "provider kind must be official or openai_compatible",
      ref_path <> ".kind"
    )
    |> maybe_error(
      is_nil(provider_name),
      :provider_name_invalid,
      "provider name is required",
      ref_path <> ".provider"
    )
    |> maybe_error(
      kind == "openai_compatible" and is_nil(endpoint),
      :provider_endpoint_missing,
      "openai_compatible provider requires endpoint",
      ref_path <> ".endpoint"
    )
    |> Kernel.++(validate_models(models, ref_path))
  end

  defp validate_provider(provider_ref, _provider_cfg) do
    [
      error(
        :provider_invalid,
        "provider config must be a map",
        path: "providers.#{provider_ref}"
      )
    ]
  end

  defp validate_models(nil, _ref_path), do: []

  defp validate_models(models, ref_path) when is_list(models) do
    Enum.with_index(models)
    |> Enum.flat_map(fn {model, idx} ->
      path = "#{ref_path}.models[#{idx}]"

      cond do
        not is_map(model) ->
          [error(:provider_model_invalid, "model entry must be a map", path: path)]

        is_nil(normalize_optional_binary(model["id"])) ->
          [error(:provider_model_missing_id, "model id is required", path: path <> ".id")]

        is_nil(normalize_optional_binary(model["name"])) ->
          [error(:provider_model_missing_name, "model name is required", path: path <> ".name")]

        not is_nil(model["default_params"]) and not is_map(model["default_params"]) ->
          [
            error(
              :provider_model_params_invalid,
              "default_params must be a map",
              path: path <> ".default_params"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp validate_models(_models, ref_path) do
    [error(:provider_models_invalid, "models must be a list", path: ref_path <> ".models")]
  end

  defp validate_agents(agents) when is_map(agents) do
    Enum.flat_map(agents, fn {agent_name, agent_cfg} ->
      validate_agent(agent_name, agent_cfg)
    end)
  end

  defp validate_agent(agent_name, agent_cfg) when is_map(agent_cfg) do
    path = "agents.#{agent_name}"

    []
    |> maybe_error(
      not is_nil(agent_cfg["name"]) and not is_binary(agent_cfg["name"]),
      :agent_name_invalid,
      "name must be a string",
      path <> ".name"
    )
    |> maybe_error(
      not is_nil(agent_cfg["description"]) and not is_binary(agent_cfg["description"]),
      :agent_description_invalid,
      "description must be a string",
      path <> ".description"
    )
    |> maybe_error(
      not is_nil(agent_cfg["system_prompt"]) and not is_binary(agent_cfg["system_prompt"]),
      :agent_system_prompt_invalid,
      "system_prompt must be a string",
      path <> ".system_prompt"
    )
    |> maybe_error(
      not is_nil(agent_cfg["capability_packs"]) and not is_list(agent_cfg["capability_packs"]),
      :agent_capability_packs_invalid,
      "capability_packs must be a list",
      path <> ".capability_packs"
    )
    |> maybe_error(
      not is_map(agent_cfg["model"]),
      :agent_model_invalid,
      "agent model config is required",
      path <> ".model"
    )
    |> maybe_error(
      not is_nil(agent_cfg["fallback_models"]) and not is_list(agent_cfg["fallback_models"]),
      :agent_fallback_models_invalid,
      "fallback_models must be a list",
      path <> ".fallback_models"
    )
    |> Kernel.++(validate_agent_model(agent_cfg["model"], path <> ".model", false))
    |> Kernel.++(validate_fallback_models(agent_cfg["fallback_models"], path))
  end

  defp validate_agent(agent_name, _agent_cfg) do
    [error(:agent_invalid, "agent config must be a map", path: "agents.#{agent_name}")]
  end

  defp validate_fallback_models(nil, _path), do: []

  defp validate_fallback_models(fallbacks, path) when is_list(fallbacks) do
    fallbacks
    |> Enum.with_index()
    |> Enum.flat_map(fn {fallback_cfg, idx} ->
      validate_agent_model(fallback_cfg, "#{path}.fallback_models[#{idx}]", true)
    end)
  end

  defp validate_fallback_models(_fallbacks, path) do
    [
      error(
        :agent_fallback_models_invalid,
        "fallback_models must be a list",
        path: path <> ".fallback_models"
      )
    ]
  end

  defp validate_agent_model(model_cfg, path, fallback?) when is_map(model_cfg) do
    model_id = normalize_optional_binary(model_cfg["model_id"] || model_cfg["id"])
    provider_ref = normalize_optional_binary(model_cfg["provider_ref"])
    provider = normalize_optional_binary(model_cfg["provider"])
    params = model_cfg["params"]
    on_errors = model_cfg["on_errors"]

    []
    |> maybe_error(
      is_nil(model_id),
      :agent_model_missing_model_id,
      "model_id is required",
      path <> ".model_id"
    )
    |> maybe_error(
      is_nil(provider_ref) and is_nil(provider),
      :agent_model_provider_invalid,
      "either provider_ref or provider must be provided",
      path
    )
    |> maybe_error(
      not is_nil(params) and not is_map(params),
      :agent_model_params_invalid,
      "params must be a map",
      path <> ".params"
    )
    |> maybe_error(
      fallback? and not is_nil(on_errors) and not is_list(on_errors),
      :agent_fallback_on_errors_invalid,
      "on_errors must be a list",
      path <> ".on_errors"
    )
  end

  defp validate_agent_model(_model_cfg, path, _fallback?) do
    [error(:agent_model_invalid, "model config must be a map", path: path)]
  end

  defp fetch_agent(agents, agent_name) when is_map(agents) do
    case Map.get(agents, agent_name) do
      %{} = agent ->
        {:ok, agent}

      _ ->
        {:error, {:agent_template_not_found, agent_name}}
    end
  end

  defp resolve_fallbacks(nil, _loaded, _agent_name, _call_params), do: {:ok, []}

  defp resolve_fallbacks(fallbacks, loaded, agent_name, call_params) when is_list(fallbacks) do
    Enum.reduce_while(fallbacks, {:ok, []}, fn fallback_cfg, {:ok, acc} ->
      case resolve_candidate(fallback_cfg, loaded, agent_name, call_params, primary?: false) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_fallbacks(_fallbacks, _loaded, agent_name, _call_params) do
    {:error, {:agent_fallback_models_invalid, agent_name}}
  end

  defp resolve_candidate(model_cfg, loaded, agent_name, call_params, opts)
       when is_map(model_cfg) and is_map(loaded) and is_map(call_params) do
    provider_ref = normalize_optional_binary(model_cfg["provider_ref"])
    primary? = Keyword.get(opts, :primary?, false)

    cond do
      is_binary(provider_ref) and provider_ref != "" ->
        resolve_provider_candidate(
          provider_ref,
          model_cfg,
          loaded,
          agent_name,
          primary?,
          call_params
        )

      true ->
        resolve_inline_candidate(model_cfg, loaded, agent_name, primary?, call_params)
    end
  end

  defp resolve_candidate(_model_cfg, _loaded, agent_name, _call_params, opts) do
    key =
      if Keyword.get(opts, :primary?, false),
        do: :agent_model_invalid,
        else: :agent_fallback_invalid

    {:error, {key, agent_name}}
  end

  defp resolve_provider_candidate(
         provider_ref,
         model_cfg,
         loaded,
         agent_name,
         primary?,
         call_params
       ) do
    with {:ok, provider_cfg} <- fetch_provider(loaded.providers, provider_ref),
         {:ok, model_id} <- fetch_model_id(model_cfg, agent_name, primary?),
         {:ok, model_entry} <- find_provider_model(provider_cfg, model_id, provider_ref),
         {:ok, request_opts} <- provider_request_opts(provider_ref, provider_cfg, loaded.secrets) do
      provider_name = normalize_optional_binary(provider_cfg["provider"]) || "openai"
      model_name = normalize_optional_binary(model_entry["name"]) || model_id

      merged_params =
        model_entry["default_params"]
        |> normalize_model_params()
        |> Map.merge(normalize_model_params(model_cfg["params"]))
        |> Map.merge(call_params)

      {:ok,
       %{
         provider_ref: provider_ref,
         provider: provider_name,
         model_id: model_id,
         model_name: model_name,
         model: "#{provider_name}:#{model_id}",
         params: merged_params,
         request_opts: request_opts,
         on_errors: normalize_on_errors(model_cfg["on_errors"], primary?)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_inline_candidate(model_cfg, loaded, agent_name, primary?, call_params) do
    with {:ok, model_id} <- fetch_model_id(model_cfg, agent_name, primary?),
         provider_name when is_binary(provider_name) <-
           normalize_optional_binary(model_cfg["provider"]),
         true <- provider_name != "",
         {:ok, request_opts} <- inline_request_opts(model_cfg, loaded.secrets) do
      merged_params =
        model_cfg["default_params"]
        |> normalize_model_params()
        |> Map.merge(normalize_model_params(model_cfg["params"]))
        |> Map.merge(call_params)

      {:ok,
       %{
         provider_ref: "__inline__",
         provider: provider_name,
         model_id: model_id,
         model_name: normalize_optional_binary(model_cfg["name"]) || model_id,
         model: "#{provider_name}:#{model_id}",
         params: merged_params,
         request_opts: request_opts,
         on_errors: normalize_on_errors(model_cfg["on_errors"], primary?)
       }}
    else
      false -> {:error, {:provider_name_invalid, agent_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:provider_name_invalid, agent_name}}
    end
  end

  defp fetch_provider(providers, provider_ref) when is_map(providers) do
    case Map.get(providers, provider_ref) do
      %{} = provider_cfg -> {:ok, provider_cfg}
      _ -> {:error, {:provider_not_found, provider_ref}}
    end
  end

  defp fetch_model_id(model_cfg, agent_name, _primary?) do
    case normalize_optional_binary(model_cfg["model_id"] || model_cfg["id"]) do
      nil -> {:error, {:agent_model_missing_model_id, agent_name}}
      id -> {:ok, id}
    end
  end

  defp find_provider_model(provider_cfg, model_id, provider_ref) do
    models = provider_cfg["models"]

    cond do
      not is_list(models) ->
        {:error, {:provider_models_invalid, provider_ref}}

      true ->
        case Enum.find(models, fn
               %{} = model -> normalize_optional_binary(model["id"]) == model_id
               _ -> false
             end) do
          %{} = model -> {:ok, model}
          _ -> {:error, {:provider_model_not_found, provider_ref, model_id}}
        end
    end
  end

  defp provider_request_opts(provider_ref, provider_cfg, secrets) do
    kind = normalize_optional_binary(provider_cfg["kind"])
    endpoint = normalize_optional_binary(provider_cfg["endpoint"] || provider_cfg["base_url"])

    with {:ok, api_key} <-
           resolve_provider_api_key(provider_ref, provider_cfg["credentials"], secrets),
         :ok <- ensure_endpoint_requirement(kind, endpoint, provider_ref) do
      opts =
        []
        |> put_if_present(:api_key, api_key)
        |> put_if_present(:base_url, endpoint)
        |> put_provider_options(provider_cfg["provider_options"])

      {:ok, opts}
    end
  end

  defp inline_request_opts(model_cfg, secrets) do
    endpoint = normalize_optional_binary(model_cfg["endpoint"] || model_cfg["base_url"])

    case resolve_inline_api_key(model_cfg["credentials"], secrets) do
      {:ok, api_key} ->
        opts =
          []
          |> put_if_present(:api_key, api_key)
          |> put_if_present(:base_url, endpoint)
          |> put_provider_options(model_cfg["provider_options"])

        {:ok, opts}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_provider_api_key(provider_ref, credentials, secrets) when is_map(credentials) do
    case Map.fetch(credentials, "api_key") do
      {:ok, api_key_cfg} ->
        resolve_api_key_value(api_key_cfg, secrets)

      :error ->
        {:error, {:provider_credentials_missing, provider_ref}}
    end
  end

  defp resolve_provider_api_key(provider_ref, _credentials, _secrets) do
    {:error, {:provider_credentials_missing, provider_ref}}
  end

  defp resolve_inline_api_key(credentials, secrets) when is_map(credentials) do
    case Map.fetch(credentials, "api_key") do
      {:ok, api_key_cfg} -> resolve_api_key_value(api_key_cfg, secrets)
      :error -> {:ok, nil}
    end
  end

  defp resolve_inline_api_key(nil, _secrets), do: {:ok, nil}
  defp resolve_inline_api_key(_credentials, _secrets), do: {:error, :provider_credentials_missing}

  defp resolve_api_key_value(value, _secrets) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: {:error, :provider_credentials_missing}, else: {:ok, normalized}
  end

  defp resolve_api_key_value(%{"secret_ref" => ref}, secrets) when is_binary(ref) do
    case resolve_secret_ref(secrets, ref) do
      {:ok, value} ->
        normalized = String.trim(value)
        if normalized == "", do: {:error, :provider_credentials_missing}, else: {:ok, normalized}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_api_key_value(_value, _secrets), do: {:error, :provider_credentials_missing}

  defp ensure_endpoint_requirement("openai_compatible", nil, provider_ref),
    do: {:error, {:provider_endpoint_missing, provider_ref}}

  defp ensure_endpoint_requirement(_kind, _endpoint, _provider_ref), do: :ok

  defp resolve_secret_ref(%{} = secrets, ref) when is_binary(ref) do
    keys = String.split(ref, ".", trim: true)

    case get_in_path(secrets, keys) do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        {:error, {:secret_ref_not_found, ref}}

      _other ->
        {:error, {:secret_value_invalid, ref}}
    end
  end

  defp resolve_secret_ref(_secrets, ref), do: {:error, {:secret_ref_not_found, ref}}

  defp get_in_path(data, []), do: data

  defp get_in_path(%{} = data, [key | rest]) do
    case Map.fetch(data, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_data, _path), do: nil

  defp put_if_present(list, _key, nil), do: list
  defp put_if_present(list, _key, ""), do: list
  defp put_if_present(list, key, value), do: Keyword.put(list, key, value)

  defp put_provider_options(opts, %{} = provider_options) do
    keyword =
      Enum.map(provider_options, fn {key, value} ->
        {to_atom_key(key), value}
      end)

    Keyword.put(opts, :provider_options, keyword)
  end

  defp put_provider_options(opts, _), do: opts

  defp normalize_on_errors(value, true), do: normalize_error_list(value, [])

  defp normalize_on_errors(value, false),
    do: normalize_error_list(value, @default_fallback_errors)

  defp normalize_error_list(nil, default), do: default

  defp normalize_error_list(list, _default) when is_list(list) do
    list
    |> Enum.map(fn
      atom when is_atom(atom) ->
        atom

      binary when is_binary(binary) ->
        binary |> String.trim() |> String.downcase() |> String.to_atom()

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_error_list(_value, default), do: default

  defp normalize_model_params(nil), do: %{}

  defp normalize_model_params(%{} = params) do
    Enum.reduce(params, %{}, fn {raw_key, value}, acc ->
      key = raw_key |> stringify_key() |> String.trim() |> String.downcase()

      case normalize_param_value(key, value) do
        {normalized_key, normalized_value} -> Map.put(acc, normalized_key, normalized_value)
        nil -> acc
      end
    end)
  end

  defp normalize_model_params(_), do: %{}

  defp normalize_call_model_params(call_overrides) when is_list(call_overrides) do
    normalize_call_model_params(Map.new(call_overrides))
  end

  defp normalize_call_model_params(%{} = call_overrides) do
    extra =
      %{}
      |> maybe_put_param("temperature", Map.get(call_overrides, :temperature))
      |> maybe_put_param("temperature", Map.get(call_overrides, "temperature"))
      |> maybe_put_param("max_tokens", Map.get(call_overrides, :max_tokens))
      |> maybe_put_param("max_tokens", Map.get(call_overrides, "max_tokens"))

    model_params =
      Map.get(call_overrides, :model_params) ||
        Map.get(call_overrides, "model_params") ||
        %{}

    model_params
    |> normalize_model_params()
    |> Map.merge(normalize_model_params(extra))
  end

  defp normalize_call_model_params(_), do: %{}

  defp maybe_put_param(acc, _key, nil), do: acc
  defp maybe_put_param(acc, key, value), do: Map.put(acc, key, value)

  defp normalize_param_value("temperature", value) when is_integer(value),
    do: {:temperature, value * 1.0}

  defp normalize_param_value("temperature", value) when is_float(value), do: {:temperature, value}

  defp normalize_param_value("temperature", value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> {:temperature, parsed}
      _ -> nil
    end
  end

  defp normalize_param_value("max_tokens", value) when is_integer(value), do: {:max_tokens, value}

  defp normalize_param_value("max_tokens", value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:max_tokens, parsed}
      _ -> nil
    end
  end

  defp normalize_param_value(key, value) when is_binary(key), do: {to_atom_key(key), value}

  defp normalize_capability_packs(nil, _agent_name), do: {:ok, []}

  defp normalize_capability_packs(packs, _agent_name) when is_list(packs) do
    normalized =
      packs
      |> Enum.map(fn
        pack when is_atom(pack) -> pack
        pack when is_binary(pack) -> to_atom_key(pack)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:ok, normalized}
  end

  defp normalize_capability_packs(_packs, agent_name),
    do: {:error, {:agent_capability_packs_invalid, agent_name}}

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_binary(_), do: nil

  defp maybe_error(errors, true, code, message, path) do
    errors ++ [error(code, message, path: path)]
  end

  defp maybe_error(errors, false, _code, _message, _path), do: errors

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    normalized = String.trim(key)

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> String.to_atom(normalized)
    end
  end

  defp to_atom_key(key), do: key |> to_string() |> to_atom_key()

  defp error(code, message, opts) do
    %{
      code: code,
      message: message,
      file: Keyword.get(opts, :file),
      path: Keyword.get(opts, :path),
      detail: Keyword.get(opts, :detail)
    }
  end

  defp type_of(value) when is_map(value), do: :map
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_binary(value), do: :binary
  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(_value), do: :unknown

  defp format_parse_reason(%{message: message} = reason) when is_binary(message) do
    line = Map.get(reason, :line)
    if is_integer(line), do: "#{message} (line #{line})", else: message
  end

  defp format_parse_reason(reason), do: inspect(reason)
end
