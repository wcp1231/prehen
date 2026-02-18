defmodule Prehen.Agent.Session.Adapters.JidoAI do
  @moduledoc false

  @behaviour Prehen.Agent.Session.Adapter

  alias Prehen.Agent.Backends.JidoAI

  @impl true
  def start_agent(config) do
    with {:ok, agent} <- JidoAI.start_agent(config) do
      {:ok, Map.put(agent, :tool_context, JidoAI.tool_context(config))}
    end
  end

  @impl true
  def stop_agent(agent) do
    JidoAI.stop_agent(agent)
  end

  @impl true
  def ask(%{pid: pid, module: module, tool_context: tool_context}, query, opts) do
    request_opts = Keyword.put_new(opts, :tool_context, tool_context)
    module.ask(pid, query, request_opts)
  end

  @impl true
  def await(%{module: module}, request, opts) do
    module.await(request, opts)
  end

  @impl true
  def cancel(%{pid: pid, module: module}, opts) do
    module.cancel(pid, opts)
  end

  @impl true
  def steer(%{pid: pid, module: module}, opts) do
    if function_exported?(module, :steer, 2) do
      module.steer(pid, opts)
    else
      module.cancel(pid, opts)
    end
  end

  @impl true
  def follow_up(%{pid: pid, module: module}, query, opts) do
    if function_exported?(module, :follow_up, 3) do
      module.follow_up(pid, query, opts)
    else
      :ok
    end
  end

  @impl true
  def status(%{pid: pid}) do
    Jido.AgentServer.status(pid)
  end
end
