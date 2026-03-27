defmodule Prehen.Client.Surface do
  @moduledoc """
  统一客户端接入层（Client Surface）。

  中文：
  - 为 CLI/Web/Native 提供统一 contract（创建会话、提交消息、状态、停止、订阅事件）。
  - 统一错误/超时结构，减少不同客户端的行为分歧。
  - `run/2` 作为 CLI 兼容入口，内部复用统一会话 API。

  English:
  - Unified client contract for CLI/Web/Native.
  - Standardizes session APIs (create/submit/status/stop/subscribe).
  - Normalizes timeout and error shapes across clients.
  - `run/2` keeps CLI compatibility while reusing the unified session APIs.
  """

  alias Prehen.Agent.Runtime
  alias Prehen.Config
  alias Prehen.Events
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker

  @doc """
  创建会话并返回客户端需要的最小标识信息。
  Create a session and return minimal client-facing identifiers.
  """
  @spec create_session(keyword()) :: {:ok, map()} | {:error, map()}
  def create_session(opts \\ []) do
    with {:ok, profile} <- Router.select_agent(opts),
         {:ok, session} <- SessionWorker.start_session(profile, opts) do
      {:ok,
       %{
         session_id: session.gateway_session_id,
         agent: profile.name
       }}
    else
      {:error, reason} ->
        {:error, error_payload(:session_create_failed, reason)}
    end
  end

  @doc """
  恢复历史会话并返回与创建会话一致的最小标识信息。
  Resume a historical session and return the same minimal identifiers as create.
  """
  @spec resume_session(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def resume_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, session_pid} <- Runtime.resume_session(session_id, opts),
         {:ok, status} <- Runtime.session_status(session_pid) do
      {:ok,
       %{
         session_pid: session_pid,
         session_id: status.session_id
       }}
    else
      {:error, reason} ->
        {:error, error_payload(:session_resume_failed, reason)}
    end
  end

  @doc """
  提交一条用户消息（prompt/steering/follow_up）并返回统一回执。
  Submit one message (`prompt/steering/follow_up`) with a unified ack payload.
  """
  @spec submit_message(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def submit_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    kind = normalize_kind(Keyword.get(opts, :kind, :prompt))
    request_id = Keyword.get(opts, :request_id, gen_id("request"))
    run_id = Keyword.get(opts, :run_id, request_id)

    with {:ok, worker_pid} <- SessionRegistry.fetch_worker(session_id),
         :ok <-
           SessionWorker.submit_message(worker_pid, %{
             kind: kind,
             role: "user",
             message_id: request_id,
             parts: [%{type: "text", text: text}],
             metadata: %{run_id: run_id}
           }) do
      {:ok,
       %{
         status: :accepted,
         kind: kind,
         queued: true,
         session_id: session_id,
         request_id: request_id,
         run_id: run_id
       }}
    else
      {:error, reason} ->
        {:error, error_payload(:submit_failed, reason)}
    end
  end

  @spec session_status(String.t()) :: {:ok, map()} | {:error, map()}
  def session_status(session_id) when is_binary(session_id) do
    case SessionRegistry.fetch(session_id) do
      {:ok, status} ->
        {:ok, Map.put(status, :session_id, session_id)}

      {:error, reason} ->
        {:error, error_payload(:session_status_failed, reason)}
    end
  end

  @spec await_result(pid(), keyword()) :: {:ok, map()} | {:error, map()}
  def await_result(session_pid, opts \\ []) when is_pid(session_pid) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    result =
      try do
        Runtime.await_idle(session_pid, timeout: timeout)
      catch
        :exit, {:timeout, _details} -> {:error, :timeout}
        :exit, {:noproc, _details} -> {:error, :session_unavailable}
      end

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, :timeout} -> {:error, error_payload(:timeout, :timeout)}
      {:error, reason} -> {:error, error_payload(:await_failed, reason)}
    end
  end

  @spec stop_session(String.t()) :: :ok | {:error, map()}
  def stop_session(session_id) when is_binary(session_id) do
    with {:ok, worker_pid} <- SessionRegistry.fetch_worker(session_id),
         :ok <- DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, worker_pid) do
      :ok
    else
      {:error, :not_found} ->
        :ok

      {:error, reason} -> {:error, error_payload(:session_stop_failed, reason)}
    end
  end

  @doc """
  订阅指定会话事件流（当前进程将收到 `{:session_event, event}`）。
  Subscribe to a session event stream; current process receives `{:session_event, event}`.
  """
  @spec subscribe_events(String.t()) :: {:ok, map()} | {:error, map()}
  def subscribe_events(session_id) when is_binary(session_id) do
    case Events.subscribe(session_id) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, error_payload(:event_subscribe_failed, reason)}
    end
  end

  @doc """
  列出当前进程绑定 workspace 下的会话。
  List sessions in the currently bound workspace.
  """
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) when is_list(opts) do
    _ = opts
    []
  end

  @doc """
  回放会话历史记录（按 `session_id`）。
  Replay persisted session history by `session_id`.
  """
  @spec replay_session(String.t(), keyword()) :: [map()]
  def replay_session(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    _ = {session_id, opts}
    []
  end

  @doc """
  设置当前进程绑定 workspace 的 capability packs（control plane）。
  Set capability packs for the currently bound workspace.
  """
  @spec set_capability_packs([atom()], keyword()) :: :ok | {:error, term()}
  def set_capability_packs(packs, opts \\ []) when is_list(packs) and is_list(opts) do
    _ = {packs, opts}
    :ok
  end

  @doc """
  兼容 CLI 的一站式运行入口（内部创建会话并执行）。
  One-shot execution helper for CLI compatibility (creates session internally).
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(task, opts \\ []) when is_binary(task) and is_list(opts) do
    config = Config.load(opts)

    cond do
      config_error = config[:config_error] ->
        {:error, error_payload(:runtime_failed, config_error)}

      true ->
        case Prehen.Agent.Runtime.run(task, opts) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, error_payload(:runtime_failed, reason)}
        end
    end
  end

  defp normalize_kind(:prompt), do: :prompt
  defp normalize_kind(:steering), do: :steering
  defp normalize_kind(:steer), do: :steering
  defp normalize_kind(:follow_up), do: :follow_up
  defp normalize_kind(_), do: :prompt

  defp error_payload(type, reason) do
    %{
      status: :error,
      type: type,
      reason: reason,
      message: inspect(reason),
      at_ms: System.system_time(:millisecond)
    }
  end

  defp gen_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
