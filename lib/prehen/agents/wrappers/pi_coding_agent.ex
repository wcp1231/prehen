defmodule Prehen.Agents.Wrappers.PiCodingAgent do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Agents.Wrappers.ExecutableHost
  alias Prehen.Config

  @behaviour Wrapper

  @recv_call_slack_ms 300
  @shell_command System.find_executable("sh") || "/bin/sh"
  @support_check_timeout_ms 5_000
  @rejected_workspace_policy_modes ~w(disabled off unmanaged)

  @impl Wrapper
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Wrapper
  def open_session(wrapper, attrs) when is_pid(wrapper) and is_map(attrs) do
    GenServer.call(wrapper, {:open_session, attrs})
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
  def stop(wrapper) when is_pid(wrapper) do
    GenServer.stop(wrapper)
  end

  @impl Wrapper
  def support_check(%SessionConfig{} = session_config) do
    with {:ok, launch} <- build_launch_spec(session_config),
         {:ok, _resolved_command} <- ExecutableHost.resolve_command(launch.executable),
         :ok <- run_support_probe(launch_for_turn(launch, "health check")) do
      :ok
    else
      {:error, reason} -> classify_preflight_error(reason)
    end
  end

  def support_check(_session_config), do: {:error, :contract_failed}

  def build_launch_spec(%SessionConfig{} = session_config) do
    with :ok <- classify_policy(session_config),
         {:ok, provider} <- fetch_required_string(session_config, :provider, :capability_failed),
         {:ok, model} <- fetch_required_string(session_config, :model, :capability_failed),
         {:ok, prompt_profile} <-
           fetch_required_string(session_config, :prompt_profile, :capability_failed),
         {:ok, workspace} <- workspace_root(session_config),
         :ok <- ensure_workspace(workspace),
         {:ok, prompt_payload} <- prompt_payload(session_config, workspace),
         {:ok, command, args, env} <- implementation_command_spec(session_config) do
      {runtime_command, runtime_args} = runtime_command(command, args, workspace)

      {:ok,
       %{
         executable: command,
         args: args,
         runtime_command: runtime_command,
         runtime_args: runtime_args,
         cwd: workspace,
         prompt_payload: prompt_payload,
         env:
           env
           |> Map.merge(%{
             "PREHEN_PROVIDER" => provider,
             "PREHEN_MODEL" => model,
             "PREHEN_PROMPT_PROFILE" => prompt_profile,
             "PREHEN_WORKSPACE" => workspace,
             "PREHEN_PROMPT" => prompt_payload
           })
           |> normalize_env()
       }}
    end
  end

  def build_launch_spec(_session_config), do: {:error, :contract_failed}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       base_session_config: Keyword.fetch!(opts, :session_config),
       runtime_session_config: nil,
       gateway_session_id: nil,
       agent_session_id: nil,
       status: :idle,
       pending_events: :queue.new(),
       recv_from: nil,
       recv_request_ref: nil,
       recv_timer_ref: nil,
       current_run: nil,
       conversation_state: %{}
     }}
  end

  @impl true
  def handle_call({:open_session, _attrs}, _from, %{agent_session_id: agent_session_id} = state)
      when is_binary(agent_session_id) do
    {:reply, {:error, :session_already_open}, state}
  end

  def handle_call({:open_session, attrs}, _from, state) do
    with {:ok, gateway_session_id} <-
           fetch_required_string(attrs, :gateway_session_id, :missing_gateway_session_id),
         {:ok, runtime_session_config} <- runtime_session_config(state.base_session_config, attrs),
         {:ok, _launch} <- build_launch_spec(runtime_session_config) do
      agent_session_id = synthetic_agent_session_id()

      {:reply, {:ok, %{agent_session_id: agent_session_id}},
       %{
         state
         | gateway_session_id: gateway_session_id,
           agent_session_id: agent_session_id,
           runtime_session_config: runtime_session_config,
           status: :idle
       }}
    end
  end

  def handle_call({:send_message, _attrs}, _from, %{runtime_session_config: nil} = state) do
    {:reply, {:error, :session_not_open}, state}
  end

  def handle_call({:send_message, _attrs}, _from, %{status: :running} = state) do
    {:reply, {:error, :session_busy}, state}
  end

  def handle_call({:send_message, attrs}, _from, state) do
    parts = Map.get(attrs, :parts) || Map.get(attrs, "parts") || []
    turn_text = extract_user_text(parts)

    with :ok <- validate_agent_session_id(state, attrs),
         {:ok, message_id} <- fetch_required_string(attrs, :message_id, :contract_failed),
         {:ok, launch} <- build_launch_spec(state.runtime_session_config),
         {:ok, host} <- start_turn_host(launch, turn_text) do
      run = %{
        host: host,
        message_id: message_id,
        buffer: "",
        header_seen?: false,
        turn_text: turn_text,
        assistant_text: ""
      }

      {:reply, :ok, %{state | status: :running, current_run: run}}
    else
      {:error, reason} when reason in [:session_not_open, :session_busy, :contract_failed] ->
        {:reply, {:error, reason}, state}

      {:error, _reason} ->
        {:reply, {:error, :launch_failed}, state}
    end
  end

  def handle_call({:send_control, _attrs}, _from, state) do
    {:reply, :ok, cancel_current_run(state)}
  end

  def handle_call({:recv_event, _timeout}, _from, %{recv_from: recv_from} = state)
      when not is_nil(recv_from) do
    {:reply, {:error, :recv_waiter_already_registered}, state}
  end

  def handle_call({:recv_event, timeout}, from, %{pending_events: pending_events} = state) do
    case :queue.out(pending_events) do
      {{:value, event}, rest} ->
        {:reply, {:ok, event}, %{state | pending_events: rest}}

      {:empty, _queue} ->
        request_ref = make_ref()
        timer_ref = Process.send_after(self(), {:recv_timeout, request_ref}, timeout)

        {:noreply,
         %{
           state
           | recv_from: from,
             recv_request_ref: request_ref,
             recv_timer_ref: timer_ref
         }}
    end
  end

  @impl true
  def handle_info(
        {:executable_host, host, {:stdout, data}},
        %{current_run: %{host: host}} = state
      ) do
    {:noreply, consume_stdout(state, data)}
  end

  def handle_info(
        {:executable_host, host, {:stderr, _data}},
        %{current_run: %{host: host}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:executable_host, host, {:exit_status, status}},
        %{current_run: %{host: host}} = state
      ) do
    {:noreply, fail_current_run(state, {:exit_status, status})}
  end

  def handle_info(
        {:executable_host, host, {:exit, reason}},
        %{current_run: %{host: host}} = state
      ) do
    {:noreply, fail_current_run(state, reason)}
  end

  def handle_info(
        {:recv_timeout, request_ref},
        %{recv_request_ref: request_ref, recv_from: from} = state
      )
      when not is_nil(from) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, clear_recv_waiter(state)}
  end

  def handle_info({:EXIT, host, reason}, %{current_run: %{host: host}} = state)
      when reason not in [:normal, :shutdown] do
    {:noreply, fail_current_run(state, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> clear_recv_waiter()
    |> maybe_stop_current_host()

    :ok
  end

  defp runtime_session_config(base_session_config, attrs) do
    session_config =
      base_session_config
      |> put_session_override(:provider, attrs)
      |> put_session_override(:model, attrs)
      |> put_session_override(:prompt_profile, attrs)
      |> put_session_override(:workspace, attrs)

    {:ok, session_config}
  end

  defp put_session_override(session_config, key, attrs) do
    case normalize_optional_string(Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))) do
      nil -> session_config
      value -> Map.put(session_config, key, value)
    end
  end

  defp synthetic_agent_session_id do
    "pi_session_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp validate_agent_session_id(%{agent_session_id: agent_session_id}, attrs) do
    case Map.get(attrs, :agent_session_id) || Map.get(attrs, "agent_session_id") do
      ^agent_session_id -> :ok
      nil -> {:error, :session_not_open}
      _other -> {:error, :session_not_open}
    end
  end

  defp start_turn_host(launch, turn_text) do
    run_launch = launch_for_turn(launch, turn_text)

    with {:ok, _resolved_command} <- ExecutableHost.resolve_command(launch.executable) do
      ExecutableHost.start_link(
        owner: self(),
        command: run_launch.command,
        args: run_launch.args,
        env: run_launch.env
      )
    end
  end

  defp launch_for_turn(launch, turn_text) do
    prompt_args =
      case normalize_optional_string(turn_text) do
        nil -> []
        text -> [text]
      end

    %{
      command: launch.runtime_command,
      args: launch.runtime_args ++ prompt_args,
      env: launch.env
    }
  end

  defp consume_stdout(state, data) do
    buffer = state.current_run.buffer <> data
    {lines, rest} = split_lines(buffer, [])

    state =
      Enum.reduce_while(
        lines,
        %{state | current_run: %{state.current_run | buffer: rest}},
        fn line, acc ->
          case consume_line(acc, line) do
            {:cont, next_state} -> {:cont, next_state}
            {:halt, next_state} -> {:halt, next_state}
          end
        end
      )

    case state.current_run do
      nil -> state
      current_run -> %{state | current_run: %{current_run | buffer: rest}}
    end
  end

  defp consume_line(state, line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:cont, state}

      not state.current_run.header_seen? ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => "session"}} ->
            {:cont, put_in(state.current_run.header_seen?, true)}

          _other ->
            {:halt, fail_current_run(state, :contract_failed)}
        end

      true ->
        case Jason.decode(trimmed) do
          {:ok, event} -> {:cont, consume_pi_event(state, event)}
          {:error, _reason} -> {:halt, fail_current_run(state, :contract_failed)}
        end
    end
  end

  defp consume_pi_event(state, %{"type" => "message_update"} = event) do
    case extract_assistant_text_delta(event) do
      nil ->
        state

      delta ->
        state
        |> append_assistant_text(delta)
        |> enqueue_event(%{
          "type" => "session.output.delta",
          "payload" => %{
            "message_id" => state.current_run.message_id,
            "text" => delta
          }
        })
    end
  end

  defp consume_pi_event(state, %{"type" => "message_end", "message" => message}) do
    put_in(
      state.current_run.assistant_text,
      extract_message_text(message) || state.current_run.assistant_text
    )
  end

  defp consume_pi_event(state, %{"type" => "agent_end"} = event) do
    assistant_text =
      extract_latest_assistant_text(Map.get(event, "messages")) ||
        state.current_run.assistant_text

    state
    |> update_conversation_state(state.current_run.turn_text, assistant_text)
    |> enqueue_event(%{
      "type" => "session.output.completed",
      "payload" => %{"message_id" => state.current_run.message_id}
    })
    |> clear_current_run()
  end

  defp consume_pi_event(state, _event), do: state

  defp append_assistant_text(state, delta) do
    update_in(state.current_run.assistant_text, &((&1 || "") <> delta))
  end

  defp update_conversation_state(state, user_text, assistant_text) do
    Map.put(state, :conversation_state, %{
      last_turn: %{
        user_text: user_text,
        assistant_text: assistant_text
      }
    })
  end

  defp clear_current_run(state) do
    %{state | status: :idle, current_run: nil}
  end

  defp cancel_current_run(%{current_run: nil} = state), do: state

  defp cancel_current_run(state) do
    state
    |> maybe_stop_current_host()
    |> clear_current_run()
  end

  defp maybe_stop_current_host(%{current_run: %{host: host}} = state) when is_pid(host) do
    maybe_stop_host(host)
    state
  end

  defp maybe_stop_current_host(state), do: state

  defp maybe_stop_host(host) when is_pid(host) do
    try do
      ExecutableHost.stop(host)
      :ok
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp maybe_stop_host(_host), do: :ok

  defp fail_current_run(%{current_run: nil} = state, _reason), do: state

  defp fail_current_run(state, reason) do
    state
    |> maybe_stop_current_host()
    |> enqueue_event(%{
      "type" => "session.error",
      "payload" => %{
        "message_id" => state.current_run.message_id,
        "reason" => format_error_reason(reason)
      }
    })
    |> clear_current_run()
  end

  defp format_error_reason(:contract_failed), do: "contract_failed"
  defp format_error_reason(:timeout), do: "timeout"
  defp format_error_reason({:exit_status, status}), do: "exit_status:#{status}"
  defp format_error_reason(reason), do: inspect(reason)

  defp enqueue_event(%{recv_from: recv_from} = state, event) when not is_nil(recv_from) do
    GenServer.reply(recv_from, {:ok, event})
    clear_recv_waiter(state)
  end

  defp enqueue_event(%{pending_events: pending_events} = state, event) do
    %{state | pending_events: :queue.in(event, pending_events)}
  end

  defp clear_recv_waiter(state) do
    if state.recv_timer_ref, do: Process.cancel_timer(state.recv_timer_ref)

    %{
      state
      | recv_from: nil,
        recv_request_ref: nil,
        recv_timer_ref: nil
    }
  end

  defp run_support_probe(run_launch) do
    with {:ok, host} <-
           ExecutableHost.start_link(
             owner: self(),
             command: run_launch.command,
             args: run_launch.args,
             env: run_launch.env
           ) do
      try do
        await_support_probe(host, %{buffer: "", header_seen?: false})
      after
        maybe_stop_host(host)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_support_probe(host, probe_state) do
    receive do
      {:executable_host, ^host, {:stdout, data}} ->
        case consume_support_stdout(probe_state, data) do
          :ok -> :ok
          {:ok, next_probe_state} -> await_support_probe(host, next_probe_state)
          {:error, reason} -> {:error, reason}
        end

      {:executable_host, ^host, {:stderr, _data}} ->
        await_support_probe(host, probe_state)

      {:executable_host, ^host, {:exit_status, _status}} ->
        {:error, :contract_failed}

      {:executable_host, ^host, {:exit, _reason}} ->
        {:error, :contract_failed}
    after
      @support_check_timeout_ms ->
        {:error, :contract_failed}
    end
  end

  defp consume_support_stdout(probe_state, data) do
    buffer = probe_state.buffer <> data
    {lines, rest} = split_lines(buffer, [])

    Enum.reduce_while(lines, {:ok, %{probe_state | buffer: rest}}, fn line, {:ok, acc} ->
      case consume_support_line(acc, line) do
        :ok -> {:halt, :ok}
        {:ok, next_acc} -> {:cont, {:ok, next_acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume_support_line(probe_state, line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:ok, probe_state}

      not probe_state.header_seen? ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => "session"}} ->
            :ok

          _other ->
            {:error, :contract_failed}
        end

      true ->
        {:ok, probe_state}
    end
  end

  defp split_lines(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> split_lines(rest, [line | acc])
      [_last] -> {Enum.reverse(acc), buffer}
      [line | remainder] -> split_lines(Enum.join(remainder, "\n"), [line | acc])
    end
  end

  defp extract_assistant_text_delta(%{
         "message" => %{"role" => "assistant"},
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
       })
       when is_binary(delta),
       do: delta

  defp extract_assistant_text_delta(_event), do: nil

  defp extract_latest_assistant_text(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} -> extract_content_text(content)
      _other -> nil
    end)
  end

  defp extract_latest_assistant_text(_messages), do: nil

  defp extract_message_text(%{"role" => "assistant", "content" => content}) do
    extract_content_text(content)
  end

  defp extract_message_text(_message), do: nil

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("")
    |> normalize_optional_string()
  end

  defp extract_content_text(_content), do: nil

  defp extract_user_text(parts) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{type: "text", text: text} when is_binary(text) -> [text]
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("")
  end

  defp extract_user_text(_parts), do: ""

  defp implementation_command_spec(%{implementation: %Implementation{} = implementation}) do
    command = normalize_optional_string(implementation.command)
    args = normalize_args(implementation.args)

    case command do
      nil -> {:error, :launch_failed}
      resolved_command -> {:ok, resolved_command, args, normalize_env(implementation.env)}
    end
  end

  defp implementation_command_spec(%{implementation: implementation})
       when is_map(implementation) do
    command =
      normalize_optional_string(
        Map.get(implementation, :command) || Map.get(implementation, "command")
      )

    args = normalize_args(Map.get(implementation, :args) || Map.get(implementation, "args"))
    env = normalize_env(Map.get(implementation, :env) || Map.get(implementation, "env"))

    case command do
      nil -> {:ok, Config.pi_coding_agent_command(), [], env}
      resolved_command -> {:ok, resolved_command, args, env}
    end
  end

  defp implementation_command_spec(_session_config) do
    {:ok, Config.pi_coding_agent_command(), [], %{}}
  end

  defp runtime_command(command, args, workspace) do
    {@shell_command,
     ["-lc", "cd \"$1\" && shift && exec \"$@\"", "prehen-pi", workspace, command | args]}
  end

  defp workspace_root(session_config) do
    case normalize_optional_string(Map.get(session_config, :workspace)) do
      nil ->
        {:error, :capability_failed}

      workspace ->
        if Path.type(workspace) == :absolute do
          {:ok, workspace}
        else
          {:error, :capability_failed}
        end
    end
  end

  defp prompt_payload(session_config, workspace) do
    case normalize_optional_string(Map.get(session_config, :prompt_context)) do
      nil ->
        prompt =
          session_config
          |> normalize_session_config()
          |> PromptContext.build(workspace: %{root_dir: workspace})
          |> Jason.encode!()

        {:ok, prompt}

      prompt ->
        {:ok, prompt}
    end
  end

  defp classify_policy(session_config) do
    mode =
      session_config
      |> Map.get(:workspace_policy, %{})
      |> workspace_policy_mode()

    if mode in @rejected_workspace_policy_modes do
      {:error, :policy_rejected}
    else
      :ok
    end
  end

  defp workspace_policy_mode(policy) when is_map(policy) do
    normalize_optional_string(Map.get(policy, :mode) || Map.get(policy, "mode"))
  end

  defp workspace_policy_mode(_policy), do: nil

  defp fetch_required_string(map, key, error_reason) do
    case normalize_optional_string(Map.get(map, key) || Map.get(map, Atom.to_string(key))) do
      nil -> {:error, error_reason}
      value -> {:ok, value}
    end
  end

  defp normalize_session_config(session_config) do
    %SessionConfig{
      profile_name: Map.get(session_config, :profile_name),
      provider: Map.get(session_config, :provider),
      model: Map.get(session_config, :model),
      prompt_profile: Map.get(session_config, :prompt_profile),
      workspace_policy: Map.get(session_config, :workspace_policy),
      implementation: Map.get(session_config, :implementation),
      workspace: Map.get(session_config, :workspace)
    }
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}

  defp ensure_workspace(workspace) when is_binary(workspace) do
    case File.mkdir_p(workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :capability_failed}
    end
  end

  defp classify_preflight_error(reason)
       when reason in [:capability_failed, :contract_failed, :policy_rejected],
       do: {:error, reason}

  defp classify_preflight_error(_reason), do: {:error, :launch_failed}
end
