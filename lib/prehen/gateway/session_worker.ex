defmodule Prehen.Gateway.SessionWorker do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.Profile
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def submit_message(worker, attrs) when is_pid(worker) and is_map(attrs) do
    GenServer.call(worker, {:submit_message, attrs})
  end

  @impl true
  def init(opts) do
    gateway_session_id = Keyword.fetch!(opts, :gateway_session_id)
    requested_agent_name = Keyword.get(opts, :agent_name)
    test_pid = Keyword.get(opts, :test_pid)
    workspace = Keyword.get(opts, :workspace)

    with {:ok, profile} <- Router.route(agent_name: requested_agent_name),
         {:ok, transport_module} <- transport_module(profile),
         {:ok, transport} <-
           transport_module.start_link(profile: profile, gateway_session_id: gateway_session_id),
         {:ok, %{agent_session_id: agent_session_id}} <-
           transport_module.open_session(transport, %{workspace: workspace}),
         :ok <-
           SessionRegistry.put(%{
             gateway_session_id: gateway_session_id,
             agent_name: profile.name,
             agent_session_id: agent_session_id,
             status: :attached
           }) do
      owner = self()
      receiver = spawn_link(fn -> recv_loop(owner, transport_module, transport) end)

      {:ok,
       %{
         gateway_session_id: gateway_session_id,
         agent_name: profile.name,
         agent_session_id: agent_session_id,
         transport_module: transport_module,
         transport: transport,
         receiver: receiver,
         test_pid: test_pid,
         seq: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit_message, attrs}, _from, state) do
    message = Map.put(attrs, :agent_session_id, state.agent_session_id)

    case state.transport_module.send_message(state.transport, message) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:transport_frame, frame}, state) when is_map(frame) do
    type = frame_value(frame, "type")
    payload = frame_value(frame, "payload") || %{}

    event =
      Envelope.build(type, %{
        gateway_session_id: state.gateway_session_id,
        agent_session_id: frame_value(payload, "agent_session_id") || state.agent_session_id,
        agent: state.agent_name,
        seq: state.seq + 1,
        payload: payload,
        metadata: %{}
      })

    dispatch_event(state, event)
    {:noreply, %{state | seq: state.seq + 1}}
  end

  def handle_info({:transport_error, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.transport) do
      state.transport_module.stop(state.transport)
    end

    :ok
  end

  defp dispatch_event(state, event) do
    if is_pid(state.test_pid) do
      send(state.test_pid, {:gateway_event, event})
    end

    Phoenix.PubSub.broadcast(
      Prehen.PubSub,
      "session:#{state.gateway_session_id}",
      {:gateway_event, event}
    )
  end

  defp recv_loop(owner, transport_module, transport) do
    case transport_module.recv_frame(transport, 30_000) do
      {:ok, frame} ->
        send(owner, {:transport_frame, frame})
        recv_loop(owner, transport_module, transport)

      {:error, reason} ->
        send(owner, {:transport_error, reason})
    end
  catch
    :exit, reason ->
      send(owner, {:transport_error, reason})
  end

  defp transport_module(%Profile{transport: :stdio}), do: {:ok, Prehen.Agents.Transports.Stdio}
  defp transport_module(%Profile{transport: module}) when is_atom(module), do: {:ok, module}
  defp transport_module(_profile), do: {:error, :unsupported_transport}

  defp frame_value(map, key) when is_binary(key) do
    atom_key =
      case key do
        "type" -> :type
        "payload" -> :payload
        "agent_session_id" -> :agent_session_id
      end

    Map.get(map, key) || Map.get(map, atom_key)
  end
end
