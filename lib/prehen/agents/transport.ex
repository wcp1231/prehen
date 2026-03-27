defmodule Prehen.Agents.Transport do
  @moduledoc false

  @callback open_session(pid(), map()) :: {:ok, map()} | {:error, term()}
  @callback recv_frame(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback send_message(pid(), map()) :: :ok | {:error, term()}
  @callback send_control(pid(), map()) :: :ok | {:error, term()}
  @callback stop(pid()) :: :ok

  def recv_frame(transport, timeout \\ 5_000) when is_pid(transport) do
    GenServer.call(transport, {:recv_frame, timeout}, timeout + 100)
  end
end
