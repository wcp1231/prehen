defmodule Prehen.Agents.Wrappers.ExecutableHost do
  @moduledoc false

  use GenServer
  import Bitwise

  @type command_spec :: %{
          required(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => map(),
          optional(:close_stdin_after_bootstrap) => boolean()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def write(host, data) when is_pid(host) do
    GenServer.call(host, {:write, data})
  end

  def stop(host) when is_pid(host) do
    GenServer.stop(host)
  end

  def support_check(%{command: command}) when is_binary(command) do
    with {:ok, _target} <- resolve_command(command),
         {:ok, _relay} <- resolve_command("python3"),
         :ok <- ensure_relay_script() do
      :ok
    else
      :error -> {:error, :relay_script_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def support_check(_command_spec), do: {:error, :invalid_command}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.get(opts, :owner, self())
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    close_stdin_after_bootstrap = Keyword.get(opts, :close_stdin_after_bootstrap, false)

    with {:ok, executable} <- resolve_command(command),
         {:ok, relay_executable} <- resolve_command("python3"),
         :ok <- ensure_relay_script(),
         {:ok, port} <- open_port(relay_executable, relay_args(), %{}),
         :ok <-
           write_bootstrap(port, executable, args, env, close_stdin_after_bootstrap) do
      {:ok, %{owner: owner, port: port, buffer: "", exit_reported?: false}}
    else
      {:bootstrap_error, reason} ->
        {:stop, reason}

      other ->
        other
    end
  end

  @impl true
  def handle_call({:write, data}, _from, %{port: port} = state) do
    reply =
      case Port.command(port, data) do
        true -> :ok
        false -> {:error, :port_closed}
      end

    {:reply, reply, state}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {events, buffer, exit_reported?} = decode_events(state.buffer <> data, state.exit_reported?)

    Enum.each(events, fn event ->
      dispatch_event(state.owner, self(), event)
    end)

    {:noreply, %{state | buffer: buffer, exit_reported?: exit_reported?}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    maybe_dispatch_exit(state.owner, self(), state.exit_reported?, status)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    if not state.exit_reported? do
      dispatch_event(state.owner, self(), {:exit, reason})
    end

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _error -> :ok
  end

  def terminate(_reason, _state), do: :ok

  @spec resolve_command(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_command(command) when is_binary(command) do
    case System.find_executable(command) || take_path_command(command) do
      nil -> {:error, {:command_not_found, command}}
      {:error, reason} -> {:error, reason}
      executable -> {:ok, executable}
    end
  end

  def resolve_command(_command), do: {:error, :invalid_command}

  defp take_path_command(command) do
    if String.contains?(command, "/") do
      validate_path_command(command)
    end
  end

  defp validate_path_command(command) do
    case File.stat(command) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 ->
        command

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:command_not_executable, command}}

      {:ok, _stat} ->
        {:error, {:command_not_executable, command}}

      {:error, _reason} ->
        nil
    end
  end

  defp open_port(command, args, env) do
    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:args, Enum.map(args, &to_string/1)},
        {:env, normalize_env(env)}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp normalize_env(_env), do: []

  defp relay_args, do: [relay_script_path()]

  defp normalize_env_map(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env_map(_env), do: %{}

  defp decode_events(buffer, exit_reported?, acc \\ [])

  defp decode_events(<<length::32, rest::binary>>, exit_reported?, acc)
       when byte_size(rest) >= length do
    <<payload::binary-size(length), remainder::binary>> = rest
    event = decode_event(payload)

    decode_events(remainder, exit_reported?(event, exit_reported?), [event | acc])
  rescue
    _error -> {Enum.reverse(acc), <<length::32, rest::binary>>, exit_reported?}
  end

  defp decode_events(buffer, exit_reported?, acc), do: {Enum.reverse(acc), buffer, exit_reported?}

  defp exit_reported?({:exit_status, _status}, _previous), do: true
  defp exit_reported?(_event, previous), do: previous

  defp dispatch_event(owner, host, event) do
    send(owner, {:executable_host, host, event})
  end

  defp maybe_dispatch_exit(owner, host, false, status),
    do: dispatch_event(owner, host, {:exit_status, status})

  defp maybe_dispatch_exit(_owner, _host, true, _status), do: :ok

  defp relay_script_path do
    Path.expand("executable_relay.py", __DIR__)
  end

  defp ensure_relay_script do
    if File.regular?(relay_script_path()), do: :ok, else: :error
  end

  defp write_bootstrap(port, command, args, env, close_stdin_after_bootstrap) do
    payload =
      %{
        type: "bootstrap",
        config: bootstrap_config(command, args, env, close_stdin_after_bootstrap)
      }
      |> Jason.encode_to_iodata!()

    case Port.command(port, encode_frame(payload)) do
      true -> :ok
      false -> {:bootstrap_error, :port_closed}
    end
  rescue
    error -> {:bootstrap_error, error}
  end

  defp bootstrap_config(command, args, env, close_stdin_after_bootstrap) do
    %{
      command: command,
      args: Enum.map(args, &to_string/1),
      env: normalize_env_map(env),
      close_stdin_after_bootstrap: close_stdin_after_bootstrap
    }
  end

  defp encode_frame(payload) when is_binary(payload), do: [<<byte_size(payload)::32>>, payload]
  defp encode_frame(payload), do: encode_frame(IO.iodata_to_binary(payload))

  defp decode_event(payload) do
    case Jason.decode!(payload) do
      %{"type" => "stdout", "data" => data} -> {:stdout, Base.decode64!(data)}
      %{"type" => "stderr", "data" => data} -> {:stderr, Base.decode64!(data)}
      %{"type" => "exit_status", "status" => status} -> {:exit_status, status}
    end
  end
end
