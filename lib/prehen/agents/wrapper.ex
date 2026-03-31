defmodule Prehen.Agents.Wrapper do
  @moduledoc false

  alias Prehen.Agents.SessionConfig

  @type wrapper :: pid()
  @type event :: map()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback open_session(wrapper(), map()) :: {:ok, map()} | {:error, term()}
  @callback send_message(wrapper(), map()) :: :ok | {:error, term()}
  @callback send_control(wrapper(), map()) :: :ok | {:error, term()}
  @callback recv_event(wrapper(), timeout()) :: {:ok, event()} | {:error, term()}
  @callback support_check(SessionConfig.t()) :: :ok | {:error, term()}
  @callback stop(wrapper()) :: :ok
end
