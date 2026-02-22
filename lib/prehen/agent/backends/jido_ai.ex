defmodule Prehen.Agent.Backends.JidoAI do
  @moduledoc false

  @behaviour Prehen.Agent.Backend
  @jido_instance Prehen.JidoRuntime
  @default_model "openai:gpt-5-mini"
  @default_system_prompt """
  You are Prehen, a local file analysis agent.
  Use tools when you need filesystem facts.
  Keep final answers concise and accurate.
  """

  alias Prehen.Agent.EventBridge

  @type agent_handle :: %{
          module: module(),
          pid: pid()
        }

  @impl true
  def run(task, config) do
    with {:ok, %{module: module, pid: pid} = handle} <- start_agent(config) do
      try do
        case module.ask_sync(pid, task,
               timeout: config[:timeout_ms],
               tool_context: tool_context(config)
             ) do
          {:ok, answer} ->
            status = safe_status(pid)
            {:ok, format_success(answer, status)}

          {:error, reason} ->
            status = safe_status(pid)
            {:error, format_error(reason, status)}
        end
      after
        _ = stop_agent(handle)
      end
    else
      {:error, _} = error -> error
    end
  end

  @spec start_agent(map()) :: {:ok, agent_handle()} | {:error, map()}
  def start_agent(config) do
    with :ok <- ensure_prerequisites(),
         :ok <- ensure_jido_runtime(),
         module <- create_ephemeral_agent_module(config),
         {:ok, pid} <- Jido.AgentServer.start(agent: module, jido: @jido_instance) do
      {:ok, %{module: module, pid: pid}}
    else
      {:error, _} = error -> error
    end
  end

  @spec stop_agent(agent_handle() | pid()) :: :ok
  def stop_agent(%{pid: pid}), do: safe_stop(pid)
  def stop_agent(pid) when is_pid(pid), do: safe_stop(pid)

  @spec tool_context(map()) :: map()
  def tool_context(config) do
    %{
      workspace_dir: config[:workspace_dir],
      read_max_bytes: config[:read_max_bytes]
    }
  end

  defp ensure_prerequisites do
    with :ok <- ensure_required_modules(),
         :ok <- ensure_runtime_apps_started() do
      :ok
    end
  end

  defp ensure_required_modules do
    cond do
      not Code.ensure_loaded?(Jido.AI.Agent) ->
        {:error, %{status: :error, reason: :jido_ai_not_available, trace: []}}

      not Code.ensure_loaded?(ReqLLM) ->
        {:error, %{status: :error, reason: :req_llm_not_available, trace: []}}

      true ->
        :ok
    end
  end

  defp ensure_runtime_apps_started do
    case Application.ensure_all_started(:jido_ai) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        {:error, %{status: :error, reason: {:jido_apps_not_started, reason}, trace: []}}
    end
  end

  defp ensure_jido_runtime do
    case Jido.start(name: @jido_instance) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, %{status: :error, reason: {:jido_runtime_start_failed, reason}, trace: []}}
    end
  rescue
    error ->
      {:error,
       %{
         status: :error,
         reason: {:jido_runtime_start_failed, Exception.message(error)},
         trace: []
       }}
  end

  defp create_ephemeral_agent_module(config) do
    suffix = :erlang.unique_integer([:positive])
    module = Module.concat([Prehen, Agent, RuntimeAgent, :"M#{suffix}"])
    max_iterations = config[:max_steps] || 8
    tools = resolve_tools(config)
    system_prompt = normalize_system_prompt(config[:system_prompt])
    llm_runtime = build_llm_runtime(config)
    primary_model = llm_runtime.primary_model

    contents =
      quote do
        use Jido.Agent,
          name: "prehen_runtime_agent",
          description: "Prehen runtime ReAct agent",
          plugins: [Jido.AI.Plugins.TaskSupervisor],
          strategy:
            {Prehen.Agent.Strategies.ReactExt,
             tools: unquote(tools),
             model: unquote(primary_model),
             llm_runtime: unquote(Macro.escape(llm_runtime.runtime)),
             max_iterations: unquote(max_iterations),
             request_policy: :reject,
             system_prompt: unquote(system_prompt)},
          schema:
            Zoi.object(%{
              __strategy__: Zoi.map() |> Zoi.default(%{}),
              model: Zoi.string() |> Zoi.default(unquote(primary_model)),
              last_query: Zoi.string() |> Zoi.default(""),
              last_answer: Zoi.string() |> Zoi.default(""),
              completed: Zoi.boolean() |> Zoi.default(false)
            })

        alias Jido.AI.Request

        @spec ask(pid() | atom() | {:via, module(), term()}, String.t(), keyword()) ::
                {:ok, Request.Handle.t()} | {:error, term()}
        def ask(pid, query, opts \\ []) when is_binary(query) do
          Request.create_and_send(
            pid,
            query,
            Keyword.merge(opts,
              signal_type: "ai.react.query",
              source: "/ai/react/agent"
            )
          )
        end

        @spec await(Request.Handle.t(), keyword()) :: {:ok, any()} | {:error, term()}
        def await(%Request.Handle{id: request_id, server: server}, opts \\ []) do
          timeout = Keyword.get(opts, :timeout, 30_000)
          deadline = System.monotonic_time(:millisecond) + timeout
          do_await(server, request_id, deadline)
        end

        @spec ask_sync(pid() | atom() | {:via, module(), term()}, String.t(), keyword()) ::
                {:ok, any()} | {:error, term()}
        def ask_sync(pid, query, opts \\ []) when is_binary(query) do
          with {:ok, request} <- ask(pid, query, opts) do
            await(request, opts)
          end
        end

        @spec cancel(pid() | atom() | {:via, module(), term()}, keyword()) ::
                :ok | {:error, term()}
        def cancel(pid, opts \\ []) do
          reason = Keyword.get(opts, :reason, :user_cancelled)
          request_id = Keyword.get(opts, :request_id)

          payload =
            %{reason: reason}
            |> then(fn p ->
              if is_binary(request_id), do: Map.put(p, :request_id, request_id), else: p
            end)

          signal = Jido.Signal.new!("ai.react.cancel", payload, source: "/ai/react/agent")
          Jido.AgentServer.cast(pid, signal)
        end

        @spec steer(pid() | atom() | {:via, module(), term()}, keyword()) ::
                :ok | {:error, term()}
        def steer(pid, opts \\ []) do
          reason = Keyword.get(opts, :reason, :steering)
          request_id = Keyword.get(opts, :request_id)

          payload =
            %{reason: reason}
            |> then(fn p ->
              if is_binary(request_id), do: Map.put(p, :request_id, request_id), else: p
            end)

          signal = Jido.Signal.new!("ai.session.steer", payload, source: "/ai/react/agent")
          Jido.AgentServer.cast(pid, signal)
        end

        @spec follow_up(pid() | atom() | {:via, module(), term()}, String.t(), keyword()) ::
                :ok | {:error, term()}
        def follow_up(pid, query, opts \\ []) when is_binary(query) do
          request_id = Keyword.get(opts, :request_id)

          payload =
            %{query: query}
            |> then(fn p ->
              if is_binary(request_id), do: Map.put(p, :request_id, request_id), else: p
            end)

          signal = Jido.Signal.new!("ai.session.follow_up", payload, source: "/ai/react/agent")
          Jido.AgentServer.cast(pid, signal)
        end

        defp do_await(server, request_id, deadline) do
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :timeout}
          else
            case Jido.AgentServer.status(server) do
              {:ok, status} ->
                snapshot = status.snapshot
                details = snapshot.details || %{}
                raw_state = status.raw_state || %{}

                active_request_id =
                  details[:active_request_id] ||
                    get_in(raw_state, [:__strategy__, :active_request_id])

                request_error = get_in(raw_state, [:__strategy__, :last_request_error]) || %{}

                cond do
                  is_map(request_error) and request_error[:request_id] == request_id ->
                    {:error, {:rejected, request_error[:reason], request_error[:message]}}

                  snapshot.done? and active_request_id == request_id and
                      snapshot.status == :success ->
                    {:ok, snapshot.result}

                  snapshot.done? and active_request_id == request_id and
                      snapshot.status == :failure ->
                    {:error,
                     {:failed, details[:termination_reason], snapshot.result,
                      %{model_events: details[:model_events], model_error: details[:model_error]}}}

                  true ->
                    Process.sleep(20)
                    do_await(server, request_id, deadline)
                end

              {:error, reason} ->
                {:error, reason}
            end
          end
        end
      end

    {:module, ^module, _, _} = Module.create(module, contents, Macro.Env.location(__ENV__))
    module
  end

  defp resolve_tools(config) do
    case Map.get(config, :tools) do
      tools when is_list(tools) ->
        tools
        |> Enum.filter(&is_atom/1)
        |> Enum.uniq()

      _ ->
        [Prehen.Actions.LS, Prehen.Actions.Read]
    end
  end

  defp build_llm_runtime(config) do
    candidates =
      case Map.get(config, :model_candidates) do
        list when is_list(list) and list != [] ->
          Enum.map(list, &normalize_candidate/1)

        _ ->
          [legacy_candidate(config)]
      end

    primary_model =
      candidates
      |> List.first()
      |> case do
        %{model: model} when is_binary(model) and model != "" -> model
        _ -> @default_model
      end

    %{
      primary_model: primary_model,
      runtime: %{candidates: candidates}
    }
  end

  defp legacy_candidate(config) do
    request_opts =
      []
      |> put_if_present(:api_key, config[:api_key])
      |> put_if_present(:base_url, config[:base_url])

    %{
      provider_ref: "__runtime__",
      provider: provider_from_model_spec(config[:model]),
      model_id: model_id_from_spec(config[:model]),
      model_name: model_id_from_spec(config[:model]),
      model: normalize_model_spec(config[:model]),
      params: normalize_model_params(Map.get(config, :model_params)),
      request_opts: request_opts,
      on_errors: []
    }
  end

  defp normalize_candidate(%{} = candidate) do
    request_opts =
      candidate
      |> Map.get(:request_opts, Map.get(candidate, "request_opts", []))
      |> normalize_request_opts()

    params =
      candidate
      |> Map.get(:params, Map.get(candidate, "params", %{}))
      |> normalize_model_params()

    on_errors =
      candidate
      |> Map.get(:on_errors, Map.get(candidate, "on_errors", []))
      |> normalize_on_errors()

    %{
      provider_ref: Map.get(candidate, :provider_ref, Map.get(candidate, "provider_ref")),
      provider: Map.get(candidate, :provider, Map.get(candidate, "provider")),
      model_id: Map.get(candidate, :model_id, Map.get(candidate, "model_id")),
      model_name: Map.get(candidate, :model_name, Map.get(candidate, "model_name")),
      model: normalize_model_spec(Map.get(candidate, :model, Map.get(candidate, "model"))),
      params: params,
      request_opts: request_opts,
      on_errors: on_errors
    }
  end

  defp normalize_candidate(_), do: legacy_candidate(%{model: @default_model})

  defp normalize_request_opts(opts) when is_list(opts) do
    opts
    |> Enum.reduce([], fn
      {key, value}, acc when key in [:api_key, :base_url] ->
        put_if_present(acc, key, value)

      {:provider_options, value}, acc when is_list(value) ->
        Keyword.put(acc, :provider_options, Enum.filter(value, &match?({_, _}, &1)))

      {"api_key", value}, acc ->
        put_if_present(acc, :api_key, value)

      {"base_url", value}, acc ->
        put_if_present(acc, :base_url, value)

      {"provider_options", value}, acc when is_map(value) ->
        provider_options =
          Enum.map(value, fn {k, v} ->
            {to_atom_key(k), v}
          end)

        Keyword.put(acc, :provider_options, provider_options)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_request_opts(%{} = opts) do
    []
    |> put_if_present(:api_key, Map.get(opts, :api_key, Map.get(opts, "api_key")))
    |> put_if_present(:base_url, Map.get(opts, :base_url, Map.get(opts, "base_url")))
    |> case do
      acc ->
        provider_options = Map.get(opts, :provider_options, Map.get(opts, "provider_options"))

        if is_map(provider_options) do
          Keyword.put(
            acc,
            :provider_options,
            Enum.map(provider_options, fn {k, v} -> {to_atom_key(k), v} end)
          )
        else
          acc
        end
    end
  end

  defp normalize_request_opts(_), do: []

  defp normalize_model_spec(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" -> @default_model
      String.contains?(normalized, ":") -> normalized
      true -> "openai:#{normalized}"
    end
  end

  defp normalize_model_spec(_), do: @default_model

  defp normalize_model_params(nil), do: %{}

  defp normalize_model_params(%{} = params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      normalized_key =
        key
        |> to_string()
        |> String.trim()
        |> String.downcase()

      case {normalized_key, value} do
        {"temperature", val} when is_integer(val) ->
          Map.put(acc, :temperature, val * 1.0)

        {"temperature", val} when is_float(val) ->
          Map.put(acc, :temperature, val)

        {"temperature", val} when is_binary(val) ->
          case Float.parse(String.trim(val)) do
            {parsed, ""} -> Map.put(acc, :temperature, parsed)
            _ -> acc
          end

        {"max_tokens", val} when is_integer(val) ->
          Map.put(acc, :max_tokens, val)

        {"max_tokens", val} when is_binary(val) ->
          case Integer.parse(String.trim(val)) do
            {parsed, ""} -> Map.put(acc, :max_tokens, parsed)
            _ -> acc
          end

        {other, val} ->
          Map.put(acc, to_atom_key(other), val)
      end
    end)
  end

  defp normalize_model_params(_), do: %{}

  defp normalize_on_errors(list) when is_list(list) do
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

  defp normalize_on_errors(_), do: []

  defp provider_from_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(normalize_model_spec(model_spec), ":", parts: 2) do
      [provider, _model_id] -> provider
      _ -> "openai"
    end
  end

  defp provider_from_model_spec(_), do: "openai"

  defp model_id_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(normalize_model_spec(model_spec), ":", parts: 2) do
      [_provider, model_id] -> model_id
      _ -> "gpt-5-mini"
    end
  end

  defp model_id_from_spec(_), do: "gpt-5-mini"

  defp normalize_system_prompt(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_system_prompt
      _ -> value
    end
  end

  defp normalize_system_prompt(_), do: @default_system_prompt

  defp put_if_present(list, _key, nil), do: list

  defp put_if_present(list, _key, value) when is_binary(value) and value == "",
    do: list

  defp put_if_present(list, key, value), do: Keyword.put(list, key, value)

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

  defp format_success(answer, status) do
    steps = extract_steps(status)
    answer_text = extract_answer(answer)

    %{
      status: :ok,
      reason: nil,
      steps: steps,
      answer: answer_text,
      trace: [
        EventBridge.project(
          "ai.request.completed",
          %{
            status: :ok,
            steps: steps,
            result: answer_text,
            framework: %{jido_ai_agent: true}
          },
          source: "prehen.backend.jido_ai"
        )
      ]
    }
  end

  defp format_error(reason, status) do
    steps = extract_steps(status)

    %{
      status: :error,
      reason: reason,
      steps: steps,
      answer: "执行失败：#{inspect(reason)}",
      trace: [
        EventBridge.project(
          "ai.request.failed",
          %{
            status: :error,
            reason: inspect(reason),
            steps: steps
          },
          source: "prehen.backend.jido_ai"
        )
      ]
    }
  end

  defp extract_answer(answer) when is_binary(answer), do: answer
  defp extract_answer(%{text: text}) when is_binary(text), do: text

  defp extract_answer(answer) do
    text = Jido.AI.Turn.extract_text(answer)
    if text == "", do: inspect(answer), else: text
  end

  defp extract_steps({:ok, %{raw_state: raw_state}}) when is_map(raw_state) do
    get_in(raw_state, [:__strategy__, :iteration]) || 0
  end

  defp extract_steps(_), do: 0

  defp safe_status(pid) do
    try do
      Jido.AgentServer.status(pid)
    rescue
      _ -> {:error, :status_unavailable}
    catch
      :exit, _ -> {:error, :status_unavailable}
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        Process.exit(pid, :normal)
        :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end
end
