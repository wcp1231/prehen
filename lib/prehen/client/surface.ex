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

  alias Prehen.Agent.EventBridge
  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.Config
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker
  alias Prehen.ProfileEnvironment
  alias Prehen.PromptBuilder

  @doc """
  创建会话并返回客户端需要的最小标识信息。
  Create a session and return minimal client-facing identifiers.
  """
  @spec create_session(keyword()) :: {:ok, map()} | {:error, map()}
  def create_session(opts \\ []) do
    with {:ok, profile} <- Router.select_agent(opts),
         {:ok, session_config} <- resolve_session_config(profile, opts),
         {:ok, session} <- SessionWorker.start_session(session_config, opts) do
      {:ok,
       %{
         session_id: session.gateway_session_id,
         agent: session_config.profile_name
       }}
    else
      {:error, reason} ->
        {:error, error_payload(:session_create_failed, reason)}
    end
  end

  @doc """
  提交一条用户消息（prompt/steering/follow_up）并返回统一回执。
  Submit one message (`prompt/steering/follow_up`) with a unified ack payload.
  """
  @spec submit_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
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
        sanitized =
          status
          |> Enum.reject(fn
            {:worker_pid, _value} -> true
            {_key, value} -> is_pid(value)
          end)
          |> Map.new()
          |> Map.put(:session_id, session_id)

        {:ok, sanitized}

      {:error, reason} ->
        {:error, error_payload(:session_status_failed, reason)}
    end
  end

  @spec stop_session(String.t()) :: :ok | {:error, map()}
  def stop_session(session_id) when is_binary(session_id) do
    with {:ok, worker_pid} <- SessionRegistry.fetch_worker(session_id),
         :ok <-
           DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, worker_pid) do
      :ok
    else
      {:error, :not_found} ->
        case SessionRegistry.fetch(session_id) do
          {:ok, %{status: status}} when status in [:stopped, :crashed] ->
            :ok

          _ ->
            {:error, error_payload(:session_stop_failed, :not_found)}
        end

      {:error, reason} ->
        {:error, error_payload(:session_stop_failed, reason)}
    end
  end

  @doc """
  兼容 CLI 的一站式运行入口（内部创建会话并执行）。
  One-shot execution helper for CLI compatibility (creates session internally).
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(task, opts \\ []) when is_binary(task) and is_list(opts) do
    config = Config.load(opts)
    timeout = Keyword.get(opts, :timeout_ms, config[:timeout_ms])
    request_id = gen_id("request")

    try do
      with {:ok, session} <- start_or_attach_gateway_session(opts),
           {:ok, response, matched_event} <-
             submit_and_await_gateway_answer(session.session_id, task, request_id, timeout),
           {:ok, trace} <- Prehen.Trace.for_session(session.session_id) do
        trace = ensure_trace_contains_event(trace, matched_event, request_id, session.session_id)

        {:ok,
         %{
           status: :ok,
           answer: extract_event_text(matched_event),
           trace: trace,
           session_id: session.session_id,
           request_id: response.request_id,
           queued: response.queued
         }}
      else
        {:error, reason} ->
          {:error, error_payload(:runtime_failed, reason)}
      end
    after
      maybe_stop_gateway_session_if_owned(opts)
    end
  end

  defp submit_and_await_gateway_answer(session_id, task, request_id, timeout_ms) do
    topic = "session:#{session_id}"
    :ok = Phoenix.PubSub.subscribe(Prehen.PubSub, topic)

    try do
      with {:ok, response} <- submit_message(session_id, task, request_id: request_id),
           {:ok, event} <- await_gateway_answer(request_id, timeout_ms) do
        {:ok, response, event}
      end
    after
      Phoenix.PubSub.unsubscribe(Prehen.PubSub, topic)
    end
  end

  defp start_or_attach_gateway_session(opts) do
    case opts |> Keyword.get(:session_id) |> normalize_session_id() do
      nil ->
        with {:ok, %{session_id: session_id}} <- create_session(opts) do
          Process.put(:prehen_gateway_session_owned, session_id)
          {:ok, %{session_id: session_id}}
        end

      session_id ->
        case SessionRegistry.fetch_worker(session_id) do
          {:ok, _worker_pid} -> {:ok, %{session_id: session_id}}
          {:error, _reason} -> {:error, {:gateway_session_not_found, session_id}}
        end
    end
  end

  defp await_gateway_answer(request_id, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_gateway_answer(request_id, deadline_ms, timeout_ms)
  end

  defp await_gateway_answer(request_id, deadline_ms, _timeout_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:gateway_event, event} ->
        if matching_output_delta?(event, request_id) do
          {:ok, event}
        else
          await_gateway_answer(request_id, deadline_ms, remaining_ms)
        end
    after
      remaining_ms -> {:error, :timeout}
    end
  end

  defp matching_output_delta?(%{type: "session.output.delta", payload: payload}, request_id)
       when is_map(payload) do
    Map.get(payload, :message_id) == request_id || Map.get(payload, "message_id") == request_id
  end

  defp matching_output_delta?(
         %{"type" => "session.output.delta", "payload" => payload},
         request_id
       )
       when is_map(payload) do
    Map.get(payload, :message_id) == request_id || Map.get(payload, "message_id") == request_id
  end

  defp matching_output_delta?(_event, _request_id), do: false

  defp ensure_trace_contains_event(trace, event, request_id, session_id) do
    present? =
      Enum.any?(trace, fn
        %{type: "session.output.delta", message_id: ^request_id} -> true
        %{"type" => "session.output.delta", "message_id" => ^request_id} -> true
        _ -> false
      end)

    if present? do
      trace
    else
      payload =
        event_payload(event)
        |> Map.put_new(:session_id, session_id)
        |> Map.put_new(:gateway_session_id, session_id)

      trace ++ [EventBridge.project("session.output.delta", payload, source: "prehen.gateway")]
    end
  end

  defp event_payload(%{payload: payload}) when is_map(payload), do: payload
  defp event_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp event_payload(_), do: %{}

  defp extract_event_text(%{payload: payload}) when is_map(payload) do
    Map.get(payload, :text) || Map.get(payload, "text") || ""
  end

  defp extract_event_text(%{"payload" => payload}) when is_map(payload) do
    Map.get(payload, :text) || Map.get(payload, "text") || ""
  end

  defp extract_event_text(_), do: ""

  defp maybe_stop_gateway_session_if_owned(opts) do
    session_id = Process.delete(:prehen_gateway_session_owned)

    cond do
      not is_binary(session_id) ->
        :ok

      Keyword.has_key?(opts, :session_id) ->
        :ok

      true ->
        stop_session(session_id)
        :ok
    end
  end

  defp normalize_kind(:prompt), do: :prompt
  defp normalize_kind(:steering), do: :steering
  defp normalize_kind(:steer), do: :steering
  defp normalize_kind(:follow_up), do: :follow_up
  defp normalize_kind(_), do: :prompt

  defp normalize_session_id(nil), do: nil

  defp normalize_session_id(session_id) when is_binary(session_id) do
    trimmed = String.trim(session_id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_session_id(session_id), do: to_string(session_id)

  defp resolve_session_config(%Profile{} = profile, opts) do
    with :ok <- reject_workspace_override(opts),
         {:ok, profile_environment} <-
           ProfileEnvironment.load(profile, prehen_home: Keyword.get(opts, :prehen_home)),
         {:ok, implementation} <- implementation_from_profile(profile) do
      provider =
        normalize_optional_string(Keyword.get(opts, :provider)) || profile.default_provider

      model = normalize_optional_string(Keyword.get(opts, :model)) || profile.default_model

      prompt_profile =
        normalize_optional_string(Keyword.get(opts, :prompt_profile)) || profile.prompt_profile

      system_prompt =
        PromptBuilder.build(
          profile_environment,
          %{profile_name: profile.name, provider: provider, model: model},
          default_capabilities()
        )

      {:ok,
       %SessionConfig{
         profile_name: profile.name,
         provider: provider,
         model: model,
         prompt_profile: prompt_profile,
         workspace_policy: profile.workspace_policy,
         implementation: implementation,
         workspace: profile_environment.workspace_dir,
         profile_dir: profile_environment.profile_dir,
         system_prompt: system_prompt
       }}
    end
  end

  defp reject_workspace_override(opts) do
    case normalize_optional_string(Keyword.get(opts, :workspace)) do
      nil -> :ok
      _workspace -> {:error, :workspace_override_not_supported}
    end
  end

  defp implementation_from_profile(%Profile{} = profile) do
    with {:ok, command, args} <- normalize_command(profile),
         {:ok, wrapper} <- normalize_wrapper(profile.wrapper) do
      {:ok,
       %Implementation{
         name: profile.implementation || profile.name,
         command: command,
         args: args,
         env: normalize_env(profile.env),
         wrapper: wrapper
       }}
    end
  end

  defp normalize_command(%Profile{command: [command | args]})
       when is_binary(command) and command != "" do
    {:ok, command, Enum.map(args, &to_string/1)}
  end

  defp normalize_command(%Profile{command: command, args: args})
       when is_binary(command) and command != "" do
    {:ok, command, Enum.map(args || [], &to_string/1)}
  end

  defp normalize_command(_profile), do: {:error, :missing_command}

  defp normalize_wrapper(wrapper) when is_atom(wrapper), do: {:ok, wrapper}
  defp normalize_wrapper(_wrapper), do: {:error, :missing_wrapper}

  defp normalize_env(env) when is_map(env), do: env
  defp normalize_env(_env), do: %{}

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp default_capabilities do
    %{skills: ["skills.search", "skills.load"]}
  end

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
