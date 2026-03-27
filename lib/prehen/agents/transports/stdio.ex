defmodule Prehen.Agents.Transports.Stdio do
  @moduledoc false

  use GenServer

  require Logger

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Protocol.Frame
  alias Prehen.Agents.Transport

  @behaviour Transport

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Transport
  def open_session(transport, attrs) when is_pid(transport) and is_map(attrs) do
    GenServer.call(transport, {:open_session, attrs})
  end

  @impl Transport
  def send_message(transport, attrs) when is_pid(transport) and is_map(attrs) do
    GenServer.call(transport, {:send_frame, Frame.session_message(attrs)})
  end

  @impl Transport
  def recv_frame(transport, timeout \\ 5_000) when is_pid(transport) do
    Transport.recv_frame(transport, timeout)
  end

  @impl Transport
  def send_control(transport, attrs) when is_pid(transport) and is_map(attrs) do
    GenServer.call(transport, {:send_frame, Frame.session_control(attrs)})
  end

  @impl Transport
  def stop(transport) when is_pid(transport) do
    GenServer.stop(transport)
  end

  @impl GenServer
  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)
    gateway_session_id = Keyword.fetch!(opts, :gateway_session_id)
    Process.flag(:trap_exit, true)

    with {:ok, command, args} <- build_command(profile),
         {:ok, port} <- open_port(command, args, profile) do
      {:ok,
       %{
         profile: profile,
         gateway_session_id: gateway_session_id,
         port: port,
         buffer: "",
         open_from: nil,
         pending_frames: :queue.new(),
         recv_from: nil
       }}
    end
  end

  @impl GenServer
  def handle_call({:open_session, attrs}, from, %{open_from: nil} = state) do
    frame =
      Frame.session_open(
        gateway_session_id: state.gateway_session_id,
        agent: state.profile.name,
        workspace: Map.get(attrs, :workspace)
      )

    case write_frame(state.port, frame) do
      :ok -> {:noreply, %{state | open_from: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_session, _attrs}, _from, state) do
    {:reply, {:error, :session_already_opening}, state}
  end

  def handle_call({:send_frame, frame}, _from, state) do
    {:reply, write_frame(state.port, frame), state}
  end

  def handle_call({:recv_frame, _timeout}, _from, %{recv_from: recv_from} = state)
      when not is_nil(recv_from) do
    {:reply, {:error, :recv_waiter_already_registered}, state}
  end

  def handle_call({:recv_frame, _timeout}, from, %{pending_frames: pending_frames} = state) do
    case :queue.out(pending_frames) do
      {{:value, frame}, rest} ->
        {:reply, {:ok, frame}, %{state | pending_frames: rest}}

      {:empty, _queue} ->
        {:noreply, %{state | recv_from: from}}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume_data(state, data)}
  end

  def handle_info(
        {port, {:exit_status, status}},
        %{port: port, open_from: from, recv_from: recv_from} = state
      ) do
    if from, do: GenServer.reply(from, {:error, {:exit_status, status}})
    if recv_from, do: GenServer.reply(recv_from, {:error, {:exit_status, status}})
    {:stop, :normal, %{state | open_from: nil, recv_from: nil}}
  end

  def handle_info(
        {:EXIT, port, reason},
        %{port: port, open_from: from, recv_from: recv_from} = state
      ) do
    if from, do: GenServer.reply(from, {:error, reason})
    if recv_from, do: GenServer.reply(recv_from, {:error, reason})
    {:stop, :normal, %{state | open_from: nil, recv_from: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp consume_data(state, data) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer, [])

    Enum.reduce(lines, %{state | buffer: rest}, fn line, acc ->
      handle_line(acc, line)
    end)
  end

  defp split_lines(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> split_lines(rest, [line | acc])
      [_last] -> {Enum.reverse(acc), buffer}
      [line | remainder] -> split_lines(Enum.join(remainder, "\n"), [line | acc])
    end
  end

  defp handle_line(state, ""), do: state

  defp handle_line(state, line) do
    trimmed = String.trim(line)

    case Jason.decode(trimmed) do
      {:ok, %{"type" => "session.opened", "payload" => payload} = frame} ->
        if state.open_from do
          agent_session_id =
            Map.get(payload, "agent_session_id") || Map.get(frame, "agent_session_id")

          GenServer.reply(state.open_from, {:ok, %{agent_session_id: agent_session_id}})
        end

        %{state | open_from: nil}

      {:ok, frame} ->
        enqueue_frame(state, frame)

      {:error, _reason} ->
        Logger.debug("ignoring non-frame stdio output",
          output: trimmed,
          agent: state.profile.name
        )

        state
    end
  end

  defp write_frame(port, frame) do
    payload = [Jason.encode_to_iodata!(frame), ?\n]

    case Port.command(port, payload) do
      true -> :ok
      false -> {:error, :port_closed}
    end
  rescue
    error -> {:error, error}
  end

  defp enqueue_frame(%{recv_from: recv_from} = state, frame) when not is_nil(recv_from) do
    GenServer.reply(recv_from, {:ok, frame})
    %{state | recv_from: nil}
  end

  defp enqueue_frame(%{pending_frames: pending_frames} = state, frame) do
    %{state | pending_frames: :queue.in(frame, pending_frames)}
  end

  defp build_command(%Profile{command: [command | args]}), do: resolve_command(command, args)

  defp build_command(%Profile{command: command, args: args}) when is_binary(command),
    do: resolve_command(command, args)

  defp build_command(_profile), do: {:error, :invalid_command}

  defp resolve_command(command, args) do
    case System.find_executable(command) || take_path_command(command) do
      nil -> {:error, {:command_not_found, command}}
      executable -> {:ok, executable, Enum.map(args, &to_string/1)}
    end
  end

  defp take_path_command(command) do
    if String.contains?(command, "/"), do: command
  end

  defp open_port(command, args, profile) do
    env =
      profile.env
      |> Enum.map(fn {key, value} ->
        {to_charlist(to_string(key)), to_charlist(to_string(value))}
      end)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, args},
        {:env, env}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end
end
