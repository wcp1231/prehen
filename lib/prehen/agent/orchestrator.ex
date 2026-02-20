defmodule Prehen.Agent.Orchestrator do
  @moduledoc false

  use GenServer

  alias Prehen.Memory
  alias Prehen.Agent.Orchestrator.Routers
  alias Prehen.Agent.Roles.Worker
  alias Prehen.Agent.WorkerSupervisor

  @default_router Routers.Hybrid

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec route(map(), map()) ::
          {:ok, atom(), %{strategy: atom(), reason: String.t()}} | {:error, term()}
  def route(request, context \\ %{}) when is_map(request) and is_map(context) do
    GenServer.call(__MODULE__, {:route, request, context})
  end

  @spec dispatch(map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(request, context \\ %{}) when is_map(request) and is_map(context) do
    GenServer.call(__MODULE__, {:dispatch, request, context}, 10_000)
  end

  @impl true
  def init(_arg) do
    router = Application.get_env(:prehen, :orchestrator_router, @default_router)
    {:ok, %{router: router}}
  end

  @impl true
  def handle_call({:route, request, context}, _from, state) do
    router = select_router(state.router, context)
    {:reply, router.select_worker(request, context), state}
  end

  def handle_call({:dispatch, request, context}, _from, state) do
    router = select_router(state.router, context)
    timeout = Map.get(context, :worker_timeout_ms, 5_000)
    run_id = map_get(request, :run_id, gen_id("run"))
    request_id = map_get(request, :request_id, gen_id("request"))
    session_id = map_get(request, :session_id, Map.get(context, :session_id))
    parent_call_id = Map.get(context, :parent_call_id)
    call_id = gen_id("call")
    memory_opts = memory_opts(context)
    memory_context = load_memory_context(session_id, memory_opts)

    worker_context =
      context
      |> Map.put_new(:run_id, run_id)
      |> Map.put_new(:request_id, request_id)
      |> Map.put_new(:session_id, session_id)
      |> Map.put(:parent_call_id, call_id)
      |> Map.put(:call_id, gen_id("worker_call"))
      |> Map.put(:memory_context, memory_context)

    result =
      with {:ok, worker_kind, route_meta} <- router.select_worker(request, context),
           {:ok, worker_pid} <-
             WorkerSupervisor.start_worker(worker_kind, request, worker_context),
           {:ok, worker_result} <- Worker.await(worker_pid, timeout: timeout) do
        worker_agent_id = Map.get(worker_result, :agent_id)

        {:ok,
         worker_result
         |> Map.put(:worker_agent_id, worker_agent_id)
         |> Map.put(:agent_id, "orchestrator")
         |> Map.put(:parent_call_id, parent_call_id)
         |> Map.put(:call_id, call_id)
         |> Map.put(:run_id, run_id)
         |> Map.put(:request_id, request_id)
         |> Map.put(:session_id, session_id)
         |> Map.put(:route, route_meta)
         |> Map.put(:worker_kind, worker_kind)}
      end

    _ = persist_memory_turn(session_id, request, result, worker_context, memory_opts)

    {:reply, result, state}
  end

  defp select_router(default_router, context) do
    case Map.get(context, :routing_mode) do
      :rule -> Routers.RuleBased
      :model -> Routers.ModelBased
      :hybrid -> Routers.Hybrid
      _ -> default_router
    end
  end

  defp map_get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp gen_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp load_memory_context(nil, _memory_opts), do: nil

  defp load_memory_context(session_id, memory_opts) when is_binary(session_id) do
    case Memory.context(session_id, memory_opts) do
      {:ok, context} -> context
      _ -> nil
    end
  end

  defp load_memory_context(_, _memory_opts), do: nil

  defp persist_memory_turn(nil, _request, _result, _context, _memory_opts), do: :ok

  defp persist_memory_turn(session_id, request, result, context, memory_opts)
       when is_binary(session_id) do
    payload = build_memory_payload(request, result, context)
    _ = Memory.record_turn(session_id, payload, memory_opts)
    :ok
  end

  defp build_memory_payload(request, {:ok, response}, context) do
    %{
      source: "orchestrator",
      status: :ok,
      request_id: Map.get(context, :request_id),
      run_id: Map.get(context, :run_id),
      input: map_get(request, :query, ""),
      output: map_get(response, :output, nil),
      worker_kind: Map.get(response, :worker_kind),
      route: Map.get(response, :route),
      at_ms: System.system_time(:millisecond),
      working_context: %{last_worker_kind: Map.get(response, :worker_kind)}
    }
  end

  defp build_memory_payload(request, {:error, reason}, context) do
    %{
      source: "orchestrator",
      status: :error,
      reason: reason,
      request_id: Map.get(context, :request_id),
      run_id: Map.get(context, :run_id),
      input: map_get(request, :query, ""),
      at_ms: System.system_time(:millisecond),
      working_context: %{last_error: inspect(reason)}
    }
  end

  defp memory_opts(context) when is_map(context) do
    []
    |> maybe_put(:ltm_adapter, Map.get(context, :ltm_adapter))
    |> maybe_put(:ltm_adapter_name, Map.get(context, :ltm_adapter_name))
    |> maybe_put(:buffer_limit, Map.get(context, :stm_buffer_limit))
    |> maybe_put(:token_budget_limit, Map.get(context, :stm_token_budget))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
