defmodule Prehen.Agent.Runtime do
  @moduledoc false

  alias Prehen.Config
  alias Prehen.Agent.Session

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(task, opts \\ []) when is_binary(task) do
    config = Config.load(opts)
    backend = config[:agent_backend]

    if backend == Prehen.Agent.Backends.JidoAI do
      run_via_session(task, config)
    else
      backend.run(task, config)
    end
  end

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    opts |> Config.load() |> Session.start()
  end

  @spec stop_session(pid()) :: :ok
  def stop_session(session_pid) when is_pid(session_pid) do
    Session.stop(session_pid)
  end

  @spec prompt(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def prompt(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.prompt(session_pid, text, opts)
  end

  @spec steer(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def steer(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.steer(session_pid, text, opts)
  end

  @spec follow_up(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def follow_up(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.follow_up(session_pid, text, opts)
  end

  @spec await_idle(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_idle(session_pid, opts \\ []) when is_pid(session_pid) do
    Session.await_idle(session_pid, opts)
  end

  defp run_via_session(task, config) do
    timeout = config[:timeout_ms] * max(config[:max_steps], 1) * 2

    with {:ok, session} <- Session.start(config) do
      try do
        with {:ok, _} <- Session.prompt(session, task),
             {:ok, result} <- Session.await_idle(session, timeout: timeout) do
          {:ok, result}
        end
      after
        if Process.alive?(session), do: Session.stop(session)
      end
    end
  end
end
