defmodule Prehen.Agent.Backends.JidoAI do
  @moduledoc false

  @behaviour Prehen.Agent.Backend
  @jido_instance Prehen.JidoRuntime

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
         :ok <- configure_req_llm(config),
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
      root_dir: config[:root_dir],
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

  defp configure_req_llm(config) do
    model = normalize_model_spec(config[:model])
    provider = provider_from_model(model)
    put_model_alias(model)

    if is_binary(config[:api_key]) and String.trim(config[:api_key]) != "" do
      ReqLLM.put_key(:"#{provider}_api_key", config[:api_key])
    end

    if is_binary(config[:base_url]) and String.trim(config[:base_url]) != "" do
      provider_cfg = Application.get_env(:req_llm, provider, [])

      Application.put_env(
        :req_llm,
        provider,
        Keyword.put(provider_cfg, :base_url, config[:base_url])
      )
    end

    :ok
  end

  defp normalize_model_spec(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" ->
        "openai:gpt-5-mini"

      String.contains?(normalized, ":") ->
        normalized

      true ->
        "openai:#{normalized}"
    end
  end

  defp normalize_model_spec(_), do: "openai:gpt-5-mini"

  defp put_model_alias(model) do
    aliases = Application.get_env(:jido_ai, :model_aliases, %{})
    Application.put_env(:jido_ai, :model_aliases, Map.put(aliases, :prehen, model))
  end

  defp provider_from_model(model) when is_binary(model) do
    with [provider_name | _] <- String.split(model, ":", parts: 2),
         true <- provider_name != "" do
      ReqLLM.Providers.list()
      |> Enum.find(:openai, fn provider -> Atom.to_string(provider) == provider_name end)
    else
      _ -> :openai
    end
  end

  defp provider_from_model(_), do: :openai

  defp create_ephemeral_agent_module(config) do
    suffix = :erlang.unique_integer([:positive])
    module = Module.concat([Prehen, Agent, RuntimeAgent, :"M#{suffix}"])
    max_iterations = config[:max_steps] || 8
    tools = resolve_tools(config)

    contents =
      quote do
        use Jido.Agent,
          name: "prehen_runtime_agent",
          description: "Prehen runtime ReAct agent",
          plugins: [Jido.AI.Plugins.TaskSupervisor],
          strategy:
            {Prehen.Agent.Strategies.ReactExt,
             tools: unquote(tools),
             model: :prehen,
             max_iterations: unquote(max_iterations),
             request_policy: :reject,
             system_prompt: """
             You are Prehen, a local file analysis agent.
             Use tools when you need filesystem facts.
             Keep final answers concise and accurate.
             """},
          schema:
            Zoi.object(%{
              __strategy__: Zoi.map() |> Zoi.default(%{}),
              model: Zoi.string() |> Zoi.default("prehen"),
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
                    {:error, {:failed, details[:termination_reason], snapshot.result}}

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
