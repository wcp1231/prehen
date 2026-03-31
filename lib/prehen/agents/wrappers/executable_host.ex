defmodule Prehen.Agents.Wrappers.ExecutableHost do
  @moduledoc false

  use GenServer

  @type command_spec :: %{
          required(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => map()
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
    case resolve_command(command) do
      {:ok, _executable} -> :ok
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
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

    with {:ok, executable} <- resolve_command(command),
         {:ok, port} <- open_port(executable, args, env, stderr_to_stdout) do
      {:ok, %{owner: owner, port: port}}
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
  def handle_info({port, {:data, data}}, %{port: port, owner: owner} = state) do
    send(owner, {:executable_host, self(), {:stdout, data}})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port, owner: owner} = state) do
    send(owner, {:executable_host, self(), {:exit_status, status}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port, owner: owner} = state) do
    send(owner, {:executable_host, self(), {:exit, reason}})
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
      executable -> {:ok, executable}
    end
  end

  def resolve_command(_command), do: {:error, :invalid_command}

  defp take_path_command(command) do
    if String.contains?(command, "/"), do: command
  end

  defp open_port(command, args, env, stderr_to_stdout) do
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:args, Enum.map(args, &to_string/1)},
      {:env, normalize_env(env)}
    ]

    port =
      Port.open(
        {:spawn_executable, command},
        maybe_merge_stderr(port_opts, stderr_to_stdout)
      )

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

  defp maybe_merge_stderr(opts, true), do: [:stderr_to_stdout | opts]
  defp maybe_merge_stderr(opts, false), do: opts
end
