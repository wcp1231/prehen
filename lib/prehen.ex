defmodule Prehen do
  @moduledoc """
  Public API for running the Prehen MVP agent.
  """

  alias Prehen.Agent.Runtime

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(task, opts \\ []) when is_binary(task) do
    Runtime.run(task, opts)
  end

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    Runtime.start_session(opts)
  end

  @spec stop_session(pid()) :: :ok
  def stop_session(session_pid) when is_pid(session_pid) do
    Runtime.stop_session(session_pid)
  end

  @spec prompt(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def prompt(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Runtime.prompt(session_pid, text, opts)
  end

  @spec steer(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def steer(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Runtime.steer(session_pid, text, opts)
  end

  @spec follow_up(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def follow_up(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Runtime.follow_up(session_pid, text, opts)
  end

  @spec await_idle(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_idle(session_pid, opts \\ []) when is_pid(session_pid) do
    Runtime.await_idle(session_pid, opts)
  end
end
