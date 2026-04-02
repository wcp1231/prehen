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
  @support_check_grace_ms 200
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
      runtime_launch_args = normalize_pi_launch_args(args, provider, model)
      {runtime_command, runtime_args} = runtime_command(command, runtime_launch_args, workspace)

      {:ok,
       %{
         executable: command,
         args: runtime_launch_args,
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
       managed_hosts: MapSet.new(),
       current_run: nil,
       conversation_state: []
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
    turn_input = build_turn_input(state.conversation_state, turn_text)

    with :ok <- validate_agent_session_id(state, attrs),
         {:ok, message_id} <- fetch_required_string(attrs, :message_id, :contract_failed),
         {:ok, launch} <- build_launch_spec(state.runtime_session_config),
         {:ok, host} <- start_turn_host(launch, turn_input) do
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
  def handle_info({:executable_host, host, event}, state) do
    {:noreply, handle_host_event(state, host, event)}
  end

  def handle_info(
        {:recv_timeout, request_ref},
        %{recv_request_ref: request_ref, recv_from: from} = state
      )
      when not is_nil(from) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, clear_recv_waiter(state)}
  end

  def handle_info({:EXIT, host, reason}, state) do
    {:noreply, handle_host_exit(state, host, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> clear_recv_waiter()
    |> maybe_stop_current_host()
    |> maybe_stop_managed_hosts()

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
        env: run_launch.env,
        close_stdin_after_bootstrap: true
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

  defp build_turn_input([_ | _] = turns, turn_text) do
    history =
      turns
      |> Enum.map(fn turn ->
        [
          "user:",
          Map.get(turn, :user_text, ""),
          "\nassistant:",
          Map.get(turn, :assistant_text, "")
        ]
      end)
      |> Enum.intersperse("\n\n")

    IO.iodata_to_binary([history, "\n\nuser:", turn_text])
  end

  defp build_turn_input(_conversation_state, turn_text), do: turn_text

  defp consume_stdout(state, data) do
    buffer = state.current_run.buffer <> data
    {lines, rest} = split_lines(buffer, [])

    state =
      Enum.reduce_while(
        lines,
        %{state | current_run: %{state.current_run | buffer: rest}},
        fn line, acc ->
          case consume_line(acc, line) do
            {:cont, %{current_run: nil} = next_state} -> {:halt, next_state}
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

  defp consume_pi_event(state, %{"type" => "message_end"}), do: state

  defp consume_pi_event(state, %{"type" => "agent_end"} = event) do
    assistant_text =
      extract_latest_assistant_text(Map.get(event, "messages")) ||
        state.current_run.assistant_text

    state
    |> update_conversation_state(state.current_run.turn_text, assistant_text)
    |> complete_current_run()
  end

  defp consume_pi_event(state, %{"type" => "agent_start"}), do: state
  defp consume_pi_event(state, %{"type" => "turn_start"}), do: state
  defp consume_pi_event(state, %{"type" => "message_start"}), do: state
  defp consume_pi_event(state, %{"type" => "turn_end"}), do: state
  defp consume_pi_event(state, %{"type" => <<"tool_execution_", _rest::binary>>}), do: state

  defp consume_pi_event(state, %{"type" => _unknown}),
    do: fail_current_run(state, :contract_failed)

  defp consume_pi_event(state, _event), do: fail_current_run(state, :contract_failed)

  defp append_assistant_text(state, delta) do
    update_in(state.current_run.assistant_text, &((&1 || "") <> delta))
  end

  defp update_conversation_state(state, user_text, assistant_text) do
    turn = %{
      user_text: user_text,
      assistant_text: assistant_text
    }

    update_in(state.conversation_state, &(&1 ++ [turn]))
  end

  defp clear_current_run(state) do
    %{state | status: :idle, current_run: nil}
  end

  defp cancel_current_run(%{current_run: nil} = state), do: state

  defp cancel_current_run(state) do
    state
    |> fail_and_complete_current_run("cancelled")
  end

  defp maybe_stop_current_host(%{current_run: %{host: host}} = state) when is_pid(host) do
    maybe_stop_host(host)
    state
  end

  defp maybe_stop_current_host(state), do: state

  defp maybe_stop_managed_hosts(%{managed_hosts: managed_hosts} = state) do
    Enum.each(managed_hosts, &maybe_stop_host/1)
    state
  end

  defp maybe_stop_host(host) when is_pid(host) do
    maybe_signal_host_os_process(host)

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

  defp maybe_signal_host_os_process(host) when is_pid(host) do
    with {:ok, os_pid} <- host_os_pid(host),
         kill when is_binary(kill) <- System.find_executable("kill") do
      _ = System.cmd(kill, ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      :ok
    else
      _other -> :ok
    end
  end

  defp maybe_signal_host_os_process(_host), do: :ok

  defp host_os_pid(host) when is_pid(host) do
    case :sys.get_state(host) do
      %{port: port} when is_port(port) ->
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} when is_integer(os_pid) -> {:ok, os_pid}
          _other -> :error
        end

      _other ->
        :error
    end
  catch
    :exit, _reason -> :error
  end

  defp host_os_pid(_host), do: :error

  defp fail_current_run(%{current_run: nil} = state, _reason), do: state

  defp fail_current_run(state, reason) do
    state
    |> fail_and_complete_current_run(format_error_reason(reason))
  end

  defp format_error_reason(:contract_failed), do: "contract_failed"
  defp format_error_reason(:timeout), do: "timeout"
  defp format_error_reason({:exit_status, status}), do: "exit_status:#{status}"
  defp format_error_reason(reason), do: inspect(reason)

  defp complete_current_run(%{current_run: %{host: host, message_id: message_id}} = state) do
    maybe_stop_host(host)

    state
    |> enqueue_event(%{
      "type" => "session.output.completed",
      "payload" => %{"message_id" => message_id}
    })
    |> clear_current_run()
  end

  defp fail_and_complete_current_run(
         %{current_run: %{host: host, message_id: message_id}} = state,
         reason
       ) do
    maybe_stop_host(host)

    state
    |> enqueue_event(%{
      "type" => "session.error",
      "payload" => %{
        "message_id" => message_id,
        "reason" => reason
      }
    })
    |> enqueue_event(%{
      "type" => "session.output.completed",
      "payload" => %{"message_id" => message_id}
    })
    |> clear_current_run()
  end

  defp handle_host_event(state, host, event) do
    cond do
      current_run_host?(state, host) ->
        handle_current_run_host_event(state, event)

      MapSet.member?(state.managed_hosts, host) ->
        handle_managed_host_event(state, host, event)

      true ->
        state
    end
  end

  defp handle_current_run_host_event(state, {:stdout, data}), do: consume_stdout(state, data)
  defp handle_current_run_host_event(state, {:stderr, _data}), do: state

  defp handle_current_run_host_event(state, {:exit_status, status}),
    do: fail_current_run(state, {:exit_status, status})

  defp handle_current_run_host_event(state, {:exit, reason}), do: fail_current_run(state, reason)

  defp handle_managed_host_event(state, host, {:exit_status, _status}),
    do: untrack_managed_host(state, host)

  defp handle_managed_host_event(state, host, {:exit, _reason}),
    do: untrack_managed_host(state, host)

  defp handle_managed_host_event(state, _host, {:stdout, _data}), do: state
  defp handle_managed_host_event(state, _host, {:stderr, _data}), do: state

  defp handle_host_exit(state, host, reason) do
    cond do
      current_run_host?(state, host) ->
        fail_current_run(state, reason)

      MapSet.member?(state.managed_hosts, host) ->
        untrack_managed_host(state, host)

      true ->
        state
    end
  end

  defp current_run_host?(%{current_run: %{host: host}}, host), do: true
  defp current_run_host?(_state, _host), do: false

  defp untrack_managed_host(%{managed_hosts: managed_hosts} = state, host) when is_pid(host) do
    %{state | managed_hosts: MapSet.delete(managed_hosts, host)}
  end

  defp untrack_managed_host(state, _host), do: state

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
    caller = self()
    result_ref = make_ref()

    probe_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(caller, {:support_probe_result, result_ref, run_support_probe_worker(run_launch)})
      end)

    receive do
      {:support_probe_result, ^result_ref, result} ->
        result
    after
      @support_check_timeout_ms + @support_check_grace_ms + 250 ->
        Process.exit(probe_pid, :kill)
        {:error, :contract_failed}
    end
  end

  defp run_support_probe_worker(run_launch) do
    with {:ok, host} <-
           ExecutableHost.start_link(
             owner: self(),
             command: run_launch.command,
             args: run_launch.args,
             env: run_launch.env,
             close_stdin_after_bootstrap: true
           ) do
      try do
        await_support_probe(host, %{buffer: "", header_seen_at: nil})
      after
        maybe_stop_host(host)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_support_probe(host, probe_state) do
    if support_probe_stable?(probe_state) do
      :ok
    else
      receive do
        {:executable_host, ^host, {:stdout, data}} ->
          case consume_support_stdout(probe_state, data) do
            {:ok, next_probe_state} -> await_support_probe(host, next_probe_state)
            {:error, reason} -> {:error, reason}
          end

        {:executable_host, ^host, {:stderr, _data}} ->
          await_support_probe(host, probe_state)

        {:executable_host, ^host, {:exit_status, 0}} ->
          if support_probe_header_seen?(probe_state), do: :ok, else: {:error, :contract_failed}

        {:executable_host, ^host, {:exit_status, _status}} ->
          {:error, :contract_failed}

        {:executable_host, ^host, {:exit, _reason}} ->
          {:error, :contract_failed}
      after
        support_probe_timeout_ms(probe_state) ->
          if support_probe_stable?(probe_state), do: :ok, else: {:error, :contract_failed}
      end
    end
  end

  defp consume_support_stdout(probe_state, data) do
    buffer = probe_state.buffer <> data
    {lines, rest} = split_lines(buffer, [])

    Enum.reduce_while(lines, {:ok, %{probe_state | buffer: rest}}, fn line, {:ok, acc} ->
      case consume_support_line(acc, line) do
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

      not support_probe_header_seen?(probe_state) ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => "session"}} ->
            {:ok, %{probe_state | header_seen_at: now_ms()}}

          _other ->
            {:error, :contract_failed}
        end

      true ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => type}} when is_binary(type) ->
            if support_probe_event_type?(type) do
              {:ok, probe_state}
            else
              {:error, :contract_failed}
            end

          {:ok, _event} ->
            {:error, :contract_failed}

          {:error, _reason} ->
            {:error, :contract_failed}
        end
    end
  end

  defp support_probe_header_seen?(%{header_seen_at: seen_at}) when is_integer(seen_at), do: true
  defp support_probe_header_seen?(_probe_state), do: false

  defp support_probe_stable?(%{header_seen_at: seen_at}) when is_integer(seen_at) do
    now_ms() - seen_at >= @support_check_grace_ms
  end

  defp support_probe_stable?(_probe_state), do: false

  defp support_probe_event_type?(type)
       when type in [
              "agent_start",
              "turn_start",
              "message_start",
              "message_update",
              "message_end",
              "turn_end",
              "agent_end"
            ],
       do: true

  defp support_probe_event_type?(<<"tool_execution_", _rest::binary>>), do: true
  defp support_probe_event_type?(_type), do: false

  defp support_probe_timeout_ms(%{header_seen_at: seen_at}) when is_integer(seen_at) do
    remaining = @support_check_grace_ms - (now_ms() - seen_at)
    max(remaining, 0)
  end

  defp support_probe_timeout_ms(_probe_state), do: @support_check_timeout_ms

  defp now_ms do
    System.monotonic_time(:millisecond)
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

  defp normalize_pi_launch_args(args, provider, model) do
    {prefix, option_args} = split_pi_launcher_prefix(List.wrap(args))

    prefix ++
      ["--mode", "json", "--provider", provider, "--model", model] ++
      strip_pi_launch_overrides(option_args)
  end

  defp split_pi_launcher_prefix(args), do: split_pi_launcher_prefix(args, [])

  defp split_pi_launcher_prefix([arg | rest], acc) do
    if String.starts_with?(arg, "-") do
      {Enum.reverse(acc), [arg | rest]}
    else
      split_pi_launcher_prefix(rest, [arg | acc])
    end
  end

  defp split_pi_launcher_prefix([], acc), do: {Enum.reverse(acc), []}

  defp strip_pi_launch_overrides(args), do: strip_pi_launch_overrides(args, [])

  defp strip_pi_launch_overrides(["--mode", _value | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides(["--provider", _value | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides(["--model", _value | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides([<<"--mode=", _value::binary>> | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides([<<"--provider=", _value::binary>> | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides([<<"--model=", _value::binary>> | rest], acc),
    do: strip_pi_launch_overrides(rest, acc)

  defp strip_pi_launch_overrides([arg | rest], acc),
    do: strip_pi_launch_overrides(rest, [arg | acc])

  defp strip_pi_launch_overrides([], acc), do: Enum.reverse(acc)

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
