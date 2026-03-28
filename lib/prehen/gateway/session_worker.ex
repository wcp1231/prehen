defmodule Prehen.Gateway.SessionWorker do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.Profile
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.InboxProjection
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Observability.TraceCollector

  def start_session(%Profile{} = profile, opts \\ []) do
    gateway_session_id = Keyword.get(opts, :gateway_session_id, gen_gateway_session_id())

    child_opts = [
      gateway_session_id: gateway_session_id,
      agent_name: profile.name,
      test_pid: Keyword.get(opts, :test_pid),
      workspace: Keyword.get(opts, :workspace)
    ]

    case DynamicSupervisor.start_child(
           Prehen.Gateway.SessionWorkerSupervisor,
           {__MODULE__, child_opts}
         ) do
      {:ok, worker_pid} ->
        {:ok,
         %{
           worker_pid: worker_pid,
           gateway_session_id: gateway_session_id
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def submit_message(worker, attrs) when is_pid(worker) and is_map(attrs) do
    GenServer.call(worker, {:submit_message, attrs})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    gateway_session_id = Keyword.fetch!(opts, :gateway_session_id)
    requested_agent_name = Keyword.get(opts, :agent_name)
    test_pid = Keyword.get(opts, :test_pid)
    workspace = Keyword.get(opts, :workspace)
    now_ms = System.system_time(:millisecond)

    with {:ok, profile} <- Router.route(agent_name: requested_agent_name),
         {:ok, transport_module} <- transport_module(profile) do
      case transport_module.start_link(profile: profile, gateway_session_id: gateway_session_id) do
        {:ok, transport} ->
          case transport_module.open_session(transport, %{workspace: workspace}) do
            {:ok, %{agent_session_id: agent_session_id}} ->
              case SessionRegistry.put(%{
                     gateway_session_id: gateway_session_id,
                     worker_pid: self(),
                     agent_name: profile.name,
                     agent_session_id: agent_session_id,
                     status: :attached
                   }) do
                :ok ->
                  :ok =
                    InboxProjection.session_started(%{
                      session_id: gateway_session_id,
                      agent_name: profile.name,
                      created_at: now_ms
                    })

                  TraceCollector.record_sync(%{
                    type: "agent.started",
                    session_id: gateway_session_id,
                    gateway_session_id: gateway_session_id,
                    agent: profile.name,
                    agent_session_id: agent_session_id
                  })

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

                {:error, reason} ->
                  safe_stop_transport(transport_module, transport)
                  {:stop, reason}
              end

            {:error, reason} ->
              safe_stop_transport(transport_module, transport)
              {:stop, reason}
          end

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit_message, attrs}, _from, state) do
    message = Map.put(attrs, :agent_session_id, state.agent_session_id)

    case state.transport_module.send_message(state.transport, message) do
      :ok ->
        :ok =
          SessionRegistry.put(%{
            gateway_session_id: state.gateway_session_id,
            status: :running
          })

        maybe_project_user_message(state.gateway_session_id, message)

        {:reply, :ok, state}

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
    project_transport_frame(state.gateway_session_id, type, payload)
    {:noreply, %{state | seq: state.seq + 1}}
  end

  def handle_info({:transport_error, reason}, state) do
    {:stop, {:transport_error, reason}, state}
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    case reason do
      :normal -> {:stop, :normal, state}
      :shutdown -> {:stop, :shutdown, state}
      {:shutdown, _} = shutdown -> {:stop, shutdown, state}
      _ -> {:stop, {:transport_exit, reason}, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    terminal_status = terminal_status(reason)

    TraceCollector.record_sync(%{
      type: "agent.stopped",
      session_id: state.gateway_session_id,
      gateway_session_id: state.gateway_session_id,
      agent: state.agent_name,
      agent_session_id: state.agent_session_id
    })

    :ok =
      InboxProjection.session_stopped(%{
        session_id: state.gateway_session_id,
        status: terminal_status
      })

    :ok =
      SessionRegistry.put(%{
        gateway_session_id: state.gateway_session_id,
        status: terminal_status,
        worker_pid: nil
      })

    safe_stop_transport(state.transport_module, state.transport)

    :ok
  end

  defp dispatch_event(state, event) do
    TraceCollector.record_sync(event)

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

  defp safe_stop_transport(transport_module, transport)
       when is_atom(transport_module) and is_pid(transport) do
    try do
      transport_module.stop(transport)
      :ok
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp safe_stop_transport(_transport_module, _transport), do: :ok

  defp project_transport_frame(session_id, "session.output.delta", payload) when is_map(payload) do
    with {:ok, message_id} <- fetch_optional_binary(payload, "message_id"),
         {:ok, text} <- fetch_optional_binary(payload, "text") do
      InboxProjection.agent_delta(%{
        session_id: session_id,
        message_id: message_id,
        text: text
      })
    else
      _ -> :ok
    end
  end

  defp project_transport_frame(session_id, "session.output.completed", payload) when is_map(payload) do
    with {:ok, message_id} <- fetch_optional_binary(payload, "message_id") do
      :ok =
        SessionRegistry.put(%{
          gateway_session_id: session_id,
          status: :idle
        })

      InboxProjection.agent_completed(%{
        session_id: session_id,
        message_id: message_id
      })
    else
      _ -> :ok
    end
  end

  defp project_transport_frame(_session_id, _type, _payload), do: :ok

  defp frame_value(map, key) when is_binary(key) do
    atom_key = String.to_existing_atom(key)

    Map.get(map, key) || Map.get(map, atom_key)
  end

  defp extract_user_text(parts) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{type: "text", text: text} when is_binary(text) -> [text]
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp extract_user_text(_parts), do: ""

  defp maybe_project_user_message(session_id, message) when is_map(message) do
    case Map.get(message, :message_id) do
      message_id when is_binary(message_id) and message_id != "" ->
        InboxProjection.user_message(%{
          session_id: session_id,
          message_id: message_id,
          text: extract_user_text(Map.get(message, :parts, []))
        })

      _ ->
        :ok
    end
  end

  defp maybe_project_user_message(_session_id, _message), do: :ok

  defp fetch_optional_binary(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp terminal_status(reason) do
    case reason do
      :normal -> :stopped
      :shutdown -> :stopped
      {:shutdown, _} -> :stopped
      _ -> :crashed
    end
  end

  defp gen_gateway_session_id do
    "gw_" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
