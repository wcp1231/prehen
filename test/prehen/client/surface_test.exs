defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case, async: false

  defmodule InspectingWrapper do
    use GenServer

    alias Prehen.Agents.Wrapper
    alias Prehen.Agents.Wrappers.Passthrough

    @behaviour Wrapper

    @impl Wrapper
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl Wrapper
    def open_session(wrapper, attrs), do: GenServer.call(wrapper, {:open_session, attrs}, 16_000)

    @impl Wrapper
    def send_message(wrapper, attrs), do: GenServer.call(wrapper, {:send_message, attrs})

    @impl Wrapper
    def send_control(wrapper, attrs), do: GenServer.call(wrapper, {:send_control, attrs})

    @impl Wrapper
    def recv_event(wrapper, timeout),
      do: GenServer.call(wrapper, {:recv_event, timeout}, timeout + 100)

    @impl Wrapper
    def support_check(session_config), do: Passthrough.support_check(session_config)

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(opts) do
      session_config = Keyword.fetch!(opts, :session_config)
      test_pid = Keyword.get(opts, :test_pid)

      {:ok, delegate} = Passthrough.start_link(session_config: session_config)

      {:ok, %{delegate: delegate, session_config: session_config, test_pid: test_pid}}
    end

    @impl true
    def handle_call({:open_session, attrs}, _from, state) do
      result = Passthrough.open_session(state.delegate, attrs)

      if match?({:ok, _opened}, result) and is_pid(state.test_pid) do
        send(state.test_pid, {:wrapper_opened, opened_payload(state.session_config, attrs)})
      end

      {:reply, result, state}
    end

    def handle_call({:send_message, attrs}, _from, state) do
      {:reply, Passthrough.send_message(state.delegate, attrs), state}
    end

    def handle_call({:send_control, attrs}, _from, state) do
      {:reply, Passthrough.send_control(state.delegate, attrs), state}
    end

    def handle_call({:recv_event, timeout}, _from, state) do
      {:reply, Passthrough.recv_event(state.delegate, timeout), state}
    end

    @impl true
    def terminate(_reason, state) do
      :ok = Passthrough.stop(state.delegate)
      :ok
    end

    defp opened_payload(session_config, attrs) do
      %{
        profile_name: session_config.profile_name,
        provider: session_config.provider,
        model: session_config.model,
        workspace:
          Map.get(attrs, :workspace) || Map.get(attrs, "workspace") || session_config.workspace,
        prompt_profile: session_config.prompt_profile,
        prompt: Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
      }
    end
  end

  defmodule CorrelatingWrapper do
    use GenServer

    alias Prehen.Agents.Wrapper

    @behaviour Wrapper

    @impl Wrapper
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl Wrapper
    def open_session(wrapper, attrs), do: GenServer.call(wrapper, {:open_session, attrs})

    @impl Wrapper
    def send_message(wrapper, attrs), do: GenServer.call(wrapper, {:send_message, attrs})

    @impl Wrapper
    def send_control(_wrapper, _attrs), do: :ok

    @impl Wrapper
    def recv_event(wrapper, timeout),
      do: GenServer.call(wrapper, {:recv_event, timeout}, timeout + 100)

    @impl Wrapper
    def support_check(_session_config), do: :ok

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(_opts) do
      {:ok, %{gateway_session_id: nil, queue: :queue.new(), recv_from: nil}}
    end

    @impl true
    def handle_call({:open_session, attrs}, _from, state) do
      gateway_session_id = Map.fetch!(attrs, :gateway_session_id)

      {:reply, {:ok, %{agent_session_id: "agent_#{gateway_session_id}"}},
       %{state | gateway_session_id: gateway_session_id}}
    end

    def handle_call({:send_message, attrs}, _from, state) do
      message_id = Map.fetch!(attrs, :message_id)
      agent_session_id = Map.fetch!(attrs, :agent_session_id)

      noise = %{
        "type" => "session.output.delta",
        "payload" => %{
          "agent_session_id" => agent_session_id,
          "message_id" => "noise_#{message_id}",
          "text" => "noise"
        }
      }

      matched = %{
        "type" => "session.output.delta",
        "payload" => %{
          "agent_session_id" => agent_session_id,
          "message_id" => message_id,
          "text" => "match:#{message_id}"
        }
      }

      {:reply, :ok, enqueue(enqueue(state, noise), matched)}
    end

    def handle_call({:recv_event, _timeout}, from, state) do
      case :queue.out(state.queue) do
        {{:value, frame}, rest} ->
          {:reply, {:ok, frame}, %{state | queue: rest}}

        {:empty, _} ->
          {:noreply, %{state | recv_from: from}}
      end
    end

    defp enqueue(%{recv_from: from} = state, frame) when not is_nil(from) do
      GenServer.reply(from, {:ok, frame})
      %{state | recv_from: nil}
    end

    defp enqueue(state, frame), do: %{state | queue: :queue.in(frame, state.queue)}
  end

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry

  setup do
    registry_pid = Process.whereis(Registry)
    original = :sys.get_state(registry_pid)

    fake_profile = %Profile{
      name: "fake_stdio",
      label: "Fake stdio",
      implementation: "fake_stdio_impl",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "fake_default",
      workspace_policy: %{mode: "scoped"}
    }

    wrapper_profile = %Profile{
      name: "coder",
      label: "Coder",
      implementation: "coder_impl",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }

    correlated_profile = %Profile{
      name: "correlated_agent",
      label: "Correlated Agent",
      implementation: "correlated_impl",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "correlated_default",
      workspace_policy: %{mode: "scoped"}
    }

    slow_open_profile = %Profile{
      name: "slow_open",
      label: "Slow Open",
      implementation: "slow_open_impl",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "slow_default",
      workspace_policy: %{mode: "scoped"}
    }

    fake_stdio_impl = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_wrapper_agent.exs"],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.Passthrough
    }

    wrapper_impl = %Implementation{
      name: "coder_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_wrapper_agent.exs"],
      env: %{},
      wrapper: InspectingWrapper
    }

    correlated_impl = %Implementation{
      name: "correlated_impl",
      command: "noop",
      args: [],
      env: %{},
      wrapper: CorrelatingWrapper
    }

    slow_open_impl = %Implementation{
      name: "slow_open_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_wrapper_agent.exs"],
      env: %{"FAKE_WRAPPER_OPEN_DELAY_MS" => "5500"},
      wrapper: Prehen.Agents.Wrappers.Passthrough
    }

    :sys.replace_state(registry_pid, fn _state ->
      %{
        ordered: [fake_profile, wrapper_profile, correlated_profile, slow_open_profile],
        by_name: %{
          "fake_stdio" => fake_profile,
          "coder" => wrapper_profile,
          "correlated_agent" => correlated_profile,
          "slow_open" => slow_open_profile
        },
        implementations_ordered: [fake_stdio_impl, wrapper_impl, correlated_impl, slow_open_impl],
        implementations_by_name: %{
          "fake_stdio_impl" => fake_stdio_impl,
          "coder_impl" => wrapper_impl,
          "correlated_impl" => correlated_impl,
          "slow_open_impl" => slow_open_impl
        }
      }
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _state -> original end)
    end)

    :ok
  end

  test "application boots gateway registry runtime children" do
    assert is_pid(Process.whereis(Prehen.Gateway.Supervisor))
    assert Enum.any?(Registry.all(), &(&1.name == "fake_stdio"))
    assert {:ok, %Prehen.Agents.Profile{name: "fake_stdio"}} = Router.select_agent()
  end

  test "create_session starts a gateway session and returns gateway metadata" do
    assert {:ok, %{session_id: gateway_session_id, agent: "fake_stdio"}} =
             Surface.create_session(agent: "fake_stdio")

    assert is_binary(gateway_session_id)
    assert {:ok, %{status: :attached}} = SessionRegistry.fetch(gateway_session_id)

    assert :ok = Surface.stop_session(gateway_session_id)
  end

  test "create_session resolves provider model prompt and workspace before wrapper startup" do
    assert {:ok, %{session_id: session_id, agent: "coder"}} =
             Surface.create_session(
               agent: "coder",
               provider: "anthropic",
               model: "claude-sonnet",
               workspace: "/tmp/prehen_surface_workspace",
               test_pid: self()
             )

    assert_receive {:wrapper_opened,
                    %{
                      profile_name: "coder",
                      provider: "anthropic",
                      model: "claude-sonnet",
                      workspace: "/tmp/prehen_surface_workspace",
                      prompt_profile: "coder_default",
                      prompt: %{
                        prompt_profile: "coder_default",
                        session: %{
                          profile_name: "coder",
                          provider: "anthropic",
                          model: "claude-sonnet"
                        },
                        workspace: %{
                          root_dir: "/tmp/prehen_surface_workspace",
                          policy: %{mode: "scoped"}
                        }
                      }
                    }}

    assert is_binary(session_id)
    assert :ok = Surface.stop_session(session_id)
  end

  test "create_session allows slow wrapper startup through the real session worker path" do
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{session_id: session_id, agent: "slow_open"}} =
             Surface.create_session(agent: "slow_open")

    assert System.monotonic_time(:millisecond) - started_at >= 5_000
    assert is_binary(session_id)
    assert :ok = Surface.stop_session(session_id)
  end

  test "submit_message and session_status use gateway session ids" do
    assert {:ok, %{session_id: session_id}} = Surface.create_session(agent: "fake_stdio")

    on_exit(fn ->
      Surface.stop_session(session_id)
    end)

    assert {:ok, submit} = Surface.submit_message(session_id, "hello gateway")
    assert submit.status == :accepted
    assert submit.session_id == session_id
    assert is_binary(submit.request_id)

    assert {:ok, status} = Surface.session_status(session_id)
    assert status.session_id == session_id
    assert status.status == :running
    assert status.agent_name == "fake_stdio"
    assert is_binary(status.agent_session_id)
    refute Map.has_key?(status, :worker_pid)
  end

  test "session_status retains stopped and crashed terminal sessions" do
    assert {:ok, %{session_id: stopped_session_id}} = Surface.create_session(agent: "fake_stdio")
    assert :ok = Surface.stop_session(stopped_session_id)

    assert {:ok, stopped_status} = Surface.session_status(stopped_session_id)
    assert stopped_status.session_id == stopped_session_id
    assert stopped_status.status == :stopped
    assert stopped_status.agent_name == "fake_stdio"
    assert is_binary(stopped_status.agent_session_id)
    refute Map.has_key?(stopped_status, :worker_pid)

    assert {:ok, %{session_id: crashed_session_id}} = Surface.create_session(agent: "fake_stdio")
    assert {:ok, worker_pid} = SessionRegistry.fetch_worker(crashed_session_id)
    wrapper_pid = :sys.get_state(worker_pid).wrapper
    transport_pid = :sys.get_state(wrapper_pid).transport
    monitor_ref = Process.monitor(worker_pid)

    Process.exit(transport_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason}, 2_000

    assert {:ok, crashed_status} = Surface.session_status(crashed_session_id)
    assert crashed_status.session_id == crashed_session_id
    assert crashed_status.status == :crashed
    assert crashed_status.agent_name == "fake_stdio"
    assert is_binary(crashed_status.agent_session_id)
    refute Map.has_key?(crashed_status, :worker_pid)
  end

  test "run/2 on reused session correlates to its own request_id and returns complete trace" do
    assert {:ok, %{session_id: session_id}} = Surface.create_session(agent: "correlated_agent")
    on_exit(fn -> Surface.stop_session(session_id) end)

    assert {:ok, result} = Surface.run("do task", session_id: session_id, timeout_ms: 1_000)

    assert result.answer == "match:#{result.request_id}"

    matching =
      Enum.find(result.trace, fn event ->
        event.type == "session.output.delta" and
          (Map.get(event, :message_id) == result.request_id or
             get_in(event, [:payload, "message_id"]) == result.request_id)
      end)

    assert matching

    assert (Map.get(matching, :text) || get_in(matching, [:payload, "text"])) ==
             "match:#{result.request_id}"
  end

  test "run/2 returns a structured error when attaching a missing gateway session" do
    assert {:error, %{type: :runtime_failed, reason: {:gateway_session_not_found, "missing"}}} =
             Surface.run("do task", session_id: "missing", timeout_ms: 100)
  end
end
