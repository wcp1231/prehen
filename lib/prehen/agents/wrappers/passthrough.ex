defmodule Prehen.Agents.Wrappers.Passthrough do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Transports.Stdio
  alias Prehen.Agents.Wrapper
  alias Prehen.Agents.Wrappers.ExecutableHost

  @behaviour Wrapper
  @open_session_timeout_ms 16_000
  @recv_call_slack_ms 300

  @impl Wrapper
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Wrapper
  def open_session(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    GenServer.call(wrapper, {:open_session, attrs}, @open_session_timeout_ms)
  end

  @impl Wrapper
  def send_message(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    GenServer.call(wrapper, {:send_message, attrs})
  end

  @impl Wrapper
  def send_control(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    GenServer.call(wrapper, {:send_control, attrs})
  end

  @impl Wrapper
  def recv_event(wrapper, timeout \\ 5_000) when is_pid(wrapper) do
    GenServer.call(wrapper, {:recv_event, timeout}, timeout + @recv_call_slack_ms)
  end

  @impl Wrapper
  def support_check(%SessionConfig{implementation: %Implementation{} = implementation}) do
    ExecutableHost.support_check(implementation)
  end

  def support_check(_session_config), do: {:error, :missing_implementation}

  @impl Wrapper
  def stop(wrapper) when is_pid(wrapper) do
    GenServer.stop(wrapper)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_config = Keyword.fetch!(opts, :session_config)

    {:ok,
     %{
       session_config: session_config,
       transport: nil,
       agent_session_id: nil
     }}
  end

  @impl true
  def handle_call({:open_session, _attrs}, _from, %{transport: transport} = state)
      when is_pid(transport) do
    {:reply, {:error, :session_already_open}, state}
  end

  def handle_call({:open_session, attrs}, _from, state) do
    session_config = state.session_config
    workspace = fetch_optional_value(attrs, :workspace) || session_config.workspace
    profile = build_profile(session_config)
    open_attrs = Map.put(attrs, :workspace, workspace)

    case fetch_required_value(attrs, :gateway_session_id) do
      {:ok, gateway_session_id} ->
        case Stdio.start_link(profile: profile, gateway_session_id: gateway_session_id) do
          {:ok, transport} ->
            case Stdio.open_session(transport, open_attrs) do
              {:ok, %{agent_session_id: agent_session_id} = opened} ->
                {:reply, {:ok, opened},
                 %{state | transport: transport, agent_session_id: agent_session_id}}

              {:error, reason} ->
                maybe_stop_transport(transport)
                {:reply, {:error, reason}, %{state | transport: nil, agent_session_id: nil}}

              other ->
                maybe_stop_transport(transport)
                {:reply, other, %{state | transport: nil, agent_session_id: nil}}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | transport: nil, agent_session_id: nil}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, attrs}, _from, %{transport: transport} = state)
      when is_pid(transport) do
    case safe_transport_call(state, fn ->
           Stdio.send_message(transport, attach_agent_session_id(attrs, state))
         end) do
      {:ok, reply, next_state} -> {:reply, reply, next_state}
      {:error, reply, next_state} -> {:reply, reply, next_state}
    end
  end

  def handle_call({:send_message, _attrs}, _from, state) do
    {:reply, {:error, :session_not_open}, state}
  end

  def handle_call({:send_control, attrs}, _from, %{transport: transport} = state)
      when is_pid(transport) do
    case safe_transport_call(state, fn ->
           Stdio.send_control(transport, attach_agent_session_id(attrs, state))
         end) do
      {:ok, reply, next_state} -> {:reply, reply, next_state}
      {:error, reply, next_state} -> {:reply, reply, next_state}
    end
  end

  def handle_call({:send_control, _attrs}, _from, state) do
    {:reply, {:error, :session_not_open}, state}
  end

  def handle_call({:recv_event, timeout}, _from, %{transport: transport} = state)
      when is_pid(transport) do
    case safe_transport_call(state, fn ->
           Stdio.recv_frame(transport, timeout)
         end) do
      {:ok, reply, next_state} -> {:reply, reply, next_state}
      {:error, reply, next_state} -> {:reply, reply, next_state}
    end
  end

  def handle_call({:recv_event, _timeout}, _from, state) do
    {:reply, {:error, :session_not_open}, state}
  end

  @impl true
  def handle_info({:EXIT, transport, _reason}, %{transport: transport} = state) do
    {:noreply, %{state | transport: nil, agent_session_id: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    maybe_stop_transport(state.transport)
    :ok
  end

  defp attach_agent_session_id(attrs, %{agent_session_id: agent_session_id}) when is_map(attrs) do
    Map.put_new(attrs, :agent_session_id, agent_session_id)
  end

  defp build_profile(%SessionConfig{
         profile_name: profile_name,
         implementation: %Implementation{} = implementation
       }) do
    Profile.bind_implementation(%Profile{name: profile_name}, implementation)
  end

  defp fetch_required_value(map, key) do
    case fetch_optional_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, missing_required_field_reason(key)}
    end
  end

  defp fetch_optional_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp missing_required_field_reason(:gateway_session_id), do: :missing_gateway_session_id
  defp missing_required_field_reason(key), do: {:missing_required_field, key}

  defp maybe_stop_transport(transport) when is_pid(transport) do
    try do
      Stdio.stop(transport)
      :ok
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp maybe_stop_transport(_transport), do: :ok

  defp safe_transport_call(state, fun) do
    {:ok, fun.(), state}
  catch
    :exit, {:timeout, {GenServer, :call, _call}} ->
      {:error, {:error, :timeout}, state}

    :exit, reason ->
      {:error, {:error, reason}, %{state | transport: nil, agent_session_id: nil}}
  end
end
