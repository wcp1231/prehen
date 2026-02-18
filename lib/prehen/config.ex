defmodule Prehen.Config do
  @moduledoc false

  @defaults %{
    model: "openai:gpt-5-mini",
    api_key: nil,
    base_url: nil,
    max_steps: 8,
    timeout_ms: 15_000,
    session_status_poll_ms: 50,
    read_max_bytes: 8_192,
    root_dir: ".",
    trace_json: false,
    agent_backend: Prehen.Agent.Backends.JidoAI,
    session_adapter: Prehen.Agent.Session.Adapters.JidoAI,
    retry_policy: Prehen.Agent.Policies.RetryPolicy,
    model_router: Prehen.Agent.Policies.ModelRouter
  }

  @spec load(keyword()) :: map()
  def load(overrides \\ []) do
    %{
      model: env_or_default(overrides, :model, "PREHEN_MODEL"),
      api_key: env_or_default(overrides, :api_key, "PREHEN_API_KEY"),
      base_url: env_or_default(overrides, :base_url, "PREHEN_BASE_URL"),
      max_steps: int_env_or_default(overrides, :max_steps, "PREHEN_MAX_STEPS"),
      timeout_ms: int_env_or_default(overrides, :timeout_ms, "PREHEN_TIMEOUT_MS"),
      session_status_poll_ms:
        int_env_or_default(overrides, :session_status_poll_ms, "PREHEN_STATUS_POLL_MS"),
      read_max_bytes: int_env_or_default(overrides, :read_max_bytes, "PREHEN_READ_MAX_BYTES"),
      root_dir: root_dir(overrides),
      trace_json: bool_env_or_default(overrides, :trace_json, "PREHEN_TRACE_JSON"),
      agent_backend: agent_backend(overrides),
      session_adapter: module_config(overrides, :session_adapter),
      retry_policy: module_config(overrides, :retry_policy),
      model_router: module_config(overrides, :model_router)
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

  defp root_dir(overrides) do
    overrides
    |> Keyword.get(
      :root_dir,
      System.get_env("PREHEN_ROOT_DIR") || Map.fetch!(@defaults, :root_dir)
    )
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
end
