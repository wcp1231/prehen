defmodule Prehen.Agent.Roles.Worker do
  @moduledoc false

  use GenServer

  @type result :: {:ok, map()} | {:error, term()}

  @spec start_link(atom(), map(), map()) :: GenServer.on_start()
  def start_link(worker_kind, request, context) do
    GenServer.start_link(__MODULE__, {worker_kind, request, context})
  end

  @spec await(pid(), keyword()) :: result()
  def await(worker_pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(worker_pid, :await, timeout)
  end

  @impl true
  def init({worker_kind, request, context}) do
    state = %{
      worker_kind: worker_kind,
      request: request,
      context: context,
      result: nil,
      waiters: []
    }

    send(self(), :run)
    {:ok, state}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:reply, result, state}
  end

  @impl true
  def handle_info(:run, state) do
    result = execute(state.worker_kind, state.request, state.context)
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | result: result, waiters: []}}
  end

  defp execute(_worker_kind, %{"force_error" => true}, _context),
    do: {:error, :forced_worker_failure}

  defp execute(_worker_kind, %{force_error: true}, _context), do: {:error, :forced_worker_failure}

  defp execute(worker_kind, request, context) do
    agent_id = "worker:#{worker_kind}"

    {:ok,
     %{
       status: :ok,
       agent_id: agent_id,
       parent_call_id: Map.get(context, :parent_call_id),
       call_id: Map.get(context, :call_id),
       run_id: Map.get(context, :run_id),
       request_id: Map.get(context, :request_id),
       worker_kind: worker_kind,
       output: Map.get(request, :query, Map.get(request, "query", "")),
       context: context
     }}
  end
end
