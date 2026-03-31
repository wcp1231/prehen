defmodule Prehen.Gateway.SessionWorker do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig
  alias Prehen.Gateway.InboxProjection
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Observability.TraceCollector

  @recv_poll_timeout_ms 100

  def start_session(%SessionConfig{} = session_config, opts \\ []) do
    gateway_session_id = Keyword.get(opts, :gateway_session_id, gen_gateway_session_id())

    :ok =
      SessionRegistry.put(
        route_state(session_config, gateway_session_id, %{
          worker_pid: nil,
          status: :starting
        })
      )

    child_opts = [
      gateway_session_id: gateway_session_id,
      session_config: session_config,
      test_pid: Keyword.get(opts, :test_pid)
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
        :ok =
          SessionRegistry.put(
            route_state(session_config, gateway_session_id, %{
              worker_pid: nil,
              status: :crashed
            })
          )

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
    session_config = Keyword.fetch!(opts, :session_config)
    test_pid = Keyword.get(opts, :test_pid)
    now_ms = System.system_time(:millisecond)

    with {:ok, wrapper_module} <- wrapper_module(session_config),
         {:ok, wrapper} <-
           wrapper_module.start_link(session_config: session_config, test_pid: test_pid) do
      case wrapper_module.open_session(
             wrapper,
             open_session_attrs(session_config, gateway_session_id)
           ) do
        {:ok, opened} ->
          with {:ok, agent_session_id} <- fetch_agent_session_id(opened),
               :ok <-
                 SessionRegistry.put(
                   route_state(session_config, gateway_session_id, %{
                     worker_pid: self(),
                     agent_session_id: agent_session_id,
                     status: :attached
                   })
                 ) do
            :ok =
              InboxProjection.session_started(%{
                session_id: gateway_session_id,
                agent_name: session_config.profile_name,
                created_at: now_ms
              })

            TraceCollector.record_sync(%{
              type: "agent.started",
              session_id: gateway_session_id,
              gateway_session_id: gateway_session_id,
              agent: session_config.profile_name,
              agent_session_id: agent_session_id
            })

            owner = self()
            receiver = spawn_link(fn -> recv_loop(owner, wrapper_module, wrapper) end)

            {:ok,
             %{
               gateway_session_id: gateway_session_id,
               agent_name: session_config.profile_name,
               agent_session_id: agent_session_id,
               wrapper_module: wrapper_module,
               wrapper: wrapper,
               receiver: receiver,
               test_pid: test_pid,
               seq: 0,
               session_config: session_config
             }}
          else
            {:error, reason} ->
              safe_stop_wrapper(wrapper_module, wrapper)
              {:stop, reason}
          end

        {:error, reason} ->
          safe_stop_wrapper(wrapper_module, wrapper)
          {:stop, reason}

        other ->
          safe_stop_wrapper(wrapper_module, wrapper)
          {:stop, other}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit_message, attrs}, _from, state) do
    message = Map.put(attrs, :agent_session_id, state.agent_session_id)

    case state.wrapper_module.send_message(state.wrapper, message) do
      :ok ->
        :ok =
          SessionRegistry.put(%{
            gateway_session_id: state.gateway_session_id,
            status: :running
          })

        maybe_project_user_message(state.gateway_session_id, message)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:wrapper_event, frame}, state) when is_map(frame) do
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
    project_wrapper_frame(state.gateway_session_id, type, payload)
    {:noreply, %{state | seq: state.seq + 1}}
  end

  def handle_info({:wrapper_error, reason}, state) do
    {:stop, {:wrapper_error, reason}, state}
  end

  def handle_info({:EXIT, wrapper, reason}, %{wrapper: wrapper} = state) do
    case reason do
      :normal -> {:stop, :normal, state}
      :shutdown -> {:stop, :shutdown, state}
      {:shutdown, _} = shutdown -> {:stop, shutdown, state}
      _ -> {:stop, {:wrapper_exit, reason}, state}
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
        agent_name: state.agent_name,
        status: terminal_status
      })

    :ok =
      SessionRegistry.put(%{
        gateway_session_id: state.gateway_session_id,
        status: terminal_status,
        worker_pid: nil
      })

    safe_stop_wrapper(state.wrapper_module, state.wrapper)

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

  defp recv_loop(owner, wrapper_module, wrapper) do
    case wrapper_module.recv_event(wrapper, @recv_poll_timeout_ms) do
      {:ok, event} ->
        send(owner, {:wrapper_event, event})
        recv_loop(owner, wrapper_module, wrapper)

      {:error, :timeout} ->
        recv_loop(owner, wrapper_module, wrapper)

      {:error, reason} ->
        send(owner, {:wrapper_error, reason})
    end
  catch
    :exit, reason ->
      send(owner, {:wrapper_error, reason})
  end

  defp wrapper_module(%SessionConfig{implementation: implementation})
       when is_map(implementation) do
    case Map.get(implementation, :wrapper) || Map.get(implementation, "wrapper") do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :unsupported_wrapper}
    end
  end

  defp wrapper_module(_session_config), do: {:error, :unsupported_wrapper}

  defp safe_stop_wrapper(wrapper_module, wrapper)
       when is_atom(wrapper_module) and is_pid(wrapper) do
    try do
      wrapper_module.stop(wrapper)
      :ok
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp safe_stop_wrapper(_wrapper_module, _wrapper), do: :ok

  defp project_wrapper_frame(session_id, "session.output.delta", payload) when is_map(payload) do
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

  defp project_wrapper_frame(session_id, "session.output.completed", payload)
       when is_map(payload) do
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

  defp project_wrapper_frame(_session_id, _type, _payload), do: :ok

  defp frame_value(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
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
    case Map.get(map, key) || Map.get(map, existing_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp fetch_agent_session_id(%{agent_session_id: agent_session_id})
       when is_binary(agent_session_id) and agent_session_id != "" do
    {:ok, agent_session_id}
  end

  defp fetch_agent_session_id(%{"agent_session_id" => agent_session_id})
       when is_binary(agent_session_id) and agent_session_id != "" do
    {:ok, agent_session_id}
  end

  defp fetch_agent_session_id(%{payload: payload}) when is_map(payload),
    do: fetch_agent_session_id(payload)

  defp fetch_agent_session_id(%{"payload" => payload}) when is_map(payload),
    do: fetch_agent_session_id(payload)

  defp fetch_agent_session_id(_opened), do: {:error, :missing_agent_session_id}

  defp open_session_attrs(%SessionConfig{} = session_config, gateway_session_id) do
    %{
      gateway_session_id: gateway_session_id,
      agent: session_config.profile_name,
      profile_name: session_config.profile_name,
      provider: session_config.provider,
      model: session_config.model,
      prompt_profile: session_config.prompt_profile,
      workspace: session_config.workspace,
      prompt: prompt_context(session_config)
    }
  end

  defp prompt_context(%SessionConfig{} = session_config) do
    workspace =
      case session_config.workspace do
        workspace when is_binary(workspace) and workspace != "" -> %{root_dir: workspace}
        _ -> %{}
      end

    PromptContext.build(session_config, workspace: workspace)
  end

  defp route_state(%SessionConfig{} = session_config, gateway_session_id, attrs) do
    Map.merge(
      %{
        gateway_session_id: gateway_session_id,
        agent_name: session_config.profile_name,
        provider: session_config.provider,
        model: session_config.model,
        prompt_profile: session_config.prompt_profile,
        workspace: session_config.workspace
      },
      attrs
    )
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
