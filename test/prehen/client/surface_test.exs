defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case, async: false

  defmodule InspectingWrapper do
    use GenServer

    alias Prehen.Agents.Wrapper
    alias Prehen.Agents.Wrappers.PiCodingAgent

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
    def support_check(session_config), do: PiCodingAgent.support_check(session_config)

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(opts) do
      session_config = Keyword.fetch!(opts, :session_config)
      test_pid = Keyword.get(opts, :test_pid)

      {:ok, delegate} = PiCodingAgent.start_link(session_config: session_config)

      {:ok, %{delegate: delegate, session_config: session_config, test_pid: test_pid}}
    end

    @impl true
    def handle_call({:open_session, attrs}, _from, state) do
      result = PiCodingAgent.open_session(state.delegate, attrs)

      if match?({:ok, _opened}, result) and is_pid(state.test_pid) do
        send(state.test_pid, {:wrapper_opened, opened_payload(state.session_config, attrs)})
      end

      {:reply, result, state}
    end

    def handle_call({:send_message, attrs}, _from, state) do
      {:reply, PiCodingAgent.send_message(state.delegate, attrs), state}
    end

    def handle_call({:send_control, attrs}, _from, state) do
      {:reply, PiCodingAgent.send_control(state.delegate, attrs), state}
    end

    def handle_call({:recv_event, timeout}, _from, state) do
      {:reply, PiCodingAgent.recv_event(state.delegate, timeout), state}
    end

    @impl true
    def terminate(_reason, state) do
      :ok = PiCodingAgent.stop(state.delegate)
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
        profile_dir: Map.get(session_config, :profile_dir),
        system_prompt: Map.get(session_config, :system_prompt),
        prompt: Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
      }
    end
  end

  defmodule SlowOpenWrapper do
    use GenServer

    alias Prehen.Agents.Wrapper
    alias Prehen.Agents.Wrappers.PiCodingAgent

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
    def support_check(session_config), do: PiCodingAgent.support_check(session_config)

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(opts) do
      session_config = Keyword.fetch!(opts, :session_config)
      {:ok, delegate} = PiCodingAgent.start_link(session_config: session_config)
      {:ok, %{delegate: delegate}}
    end

    @impl true
    def handle_call({:open_session, attrs}, _from, state) do
      Process.sleep(5_500)
      {:reply, PiCodingAgent.open_session(state.delegate, attrs), state}
    end

    def handle_call({:send_message, attrs}, _from, state) do
      {:reply, PiCodingAgent.send_message(state.delegate, attrs), state}
    end

    def handle_call({:send_control, attrs}, _from, state) do
      {:reply, PiCodingAgent.send_control(state.delegate, attrs), state}
    end

    def handle_call({:recv_event, timeout}, _from, state) do
      {:reply, PiCodingAgent.recv_event(state.delegate, timeout), state}
    end

    @impl true
    def terminate(_reason, state) do
      :ok = PiCodingAgent.stop(state.delegate)
      :ok
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
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.TestSupport.PiAgentFixture

  setup_all do
    Application.ensure_all_started(:prehen)
    :ok
  end

  setup do
    original = PiAgentFixture.replace_registry!(registry_state())
    prehen_home = tmp_prehen_home("surface")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    System.put_env("PREHEN_HOME", prehen_home)
    write_profile_home!(prehen_home, "coder")
    write_profile_home!(prehen_home, "inspecting")
    write_profile_home!(prehen_home, "correlated_agent")
    write_profile_home!(prehen_home, "slow_open")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "application boots gateway registry runtime children" do
    assert is_pid(Process.whereis(Prehen.Gateway.Supervisor))
    assert Enum.any?(Registry.all(), &(&1.name == "coder"))
    assert {:ok, %Prehen.Agents.Profile{name: "coder"}} = Router.select_agent()
  end

  test "create_session starts a gateway session and returns gateway metadata", %{
    prehen_home: prehen_home
  } do
    assert {:ok, %{session_id: gateway_session_id, agent: "coder"}} =
             Surface.create_session(agent: "coder", prehen_home: prehen_home)

    assert is_binary(gateway_session_id)

    assert {:ok, %{status: :attached, workspace: workspace}} =
             SessionRegistry.fetch(gateway_session_id)

    assert workspace == profile_workspace(prehen_home, "coder")

    assert :ok = Surface.stop_session(gateway_session_id)
  end

  test "create_session resolves provider model prompt and workspace before wrapper startup", %{
    prehen_home: prehen_home
  } do
    expected_workspace = profile_workspace(prehen_home, "inspecting")

    assert {:ok, %{session_id: session_id, agent: "inspecting"}} =
             Surface.create_session(
               agent: "inspecting",
               provider: "anthropic",
               model: "claude-sonnet",
               prehen_home: prehen_home,
               test_pid: self()
             )

    assert_receive {:wrapper_opened,
                    %{
                      profile_name: "inspecting",
                      provider: "anthropic",
                      model: "claude-sonnet",
                      workspace: ^expected_workspace,
                      prompt_profile: "coder_default",
                      profile_dir: ^expected_workspace,
                      system_prompt: system_prompt,
                      prompt: %{
                        prompt_profile: "coder_default",
                        session: %{
                          profile_name: "inspecting",
                          provider: "anthropic",
                          model: "claude-sonnet"
                        },
                        workspace: %{
                          root_dir: ^expected_workspace,
                          policy: %{mode: "scoped"}
                        },
                        capabilities: %{
                          skills: skills
                        }
                      }
                    }}

    assert Enum.sort(skills) == ["skills.load", "skills.search"]

    assert system_prompt =~ "SOUL for inspecting."
    assert system_prompt =~ "AGENTS for inspecting."
    assert system_prompt =~ "workspace: #{expected_workspace}"
    assert system_prompt =~ "skills.search"
    assert system_prompt =~ "skills.load"

    assert is_binary(session_id)
    assert :ok = Surface.stop_session(session_id)
  end

  test "create_session resolves the fixed profile workspace when workspace is omitted", %{
    prehen_home: prehen_home
  } do
    expected_workspace = profile_workspace(prehen_home, "inspecting")

    assert {:ok, %{session_id: session_id, agent: "inspecting"}} =
             Surface.create_session(agent: "inspecting", prehen_home: prehen_home, test_pid: self())

    assert_receive {:wrapper_opened,
                    %{
                      profile_name: "inspecting",
                      workspace: ^expected_workspace,
                      prompt: %{
                        workspace: %{
                          root_dir: ^expected_workspace,
                          policy: %{mode: "scoped"}
                        }
                      }
                    }}

    assert File.dir?(expected_workspace)
    assert Path.type(expected_workspace) == :absolute

    assert {:ok, %{workspace: ^expected_workspace, status: :attached}} =
             Surface.session_status(session_id)

    on_exit(fn -> :ok = Surface.stop_session(session_id) end)
  end

  test "create_session rejects ad hoc workspace overrides once profile workspaces are fixed", %{
    prehen_home: prehen_home
  } do
    assert {:error, %{reason: :workspace_override_not_supported}} =
             Surface.create_session(
               agent: "coder",
               prehen_home: prehen_home,
               workspace: "/tmp/other"
             )
  end

  test "create_session allows slow wrapper startup through the real session worker path", %{
    prehen_home: prehen_home
  } do
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{session_id: session_id, agent: "slow_open"}} =
             Surface.create_session(agent: "slow_open", prehen_home: prehen_home)

    assert System.monotonic_time(:millisecond) - started_at >= 5_000
    assert is_binary(session_id)
    assert :ok = Surface.stop_session(session_id)
  end

  test "submit_message and session_status use gateway session ids", %{prehen_home: prehen_home} do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "coder", prehen_home: prehen_home)

    on_exit(fn -> Surface.stop_session(session_id) end)

    assert {:ok, submit} = Surface.submit_message(session_id, "hello gateway")
    assert submit.status == :accepted
    assert submit.session_id == session_id
    assert is_binary(submit.request_id)

    assert {:ok, status} = Surface.session_status(session_id)
    assert status.session_id == session_id
    assert status.status == :running
    assert status.agent_name == "coder"
    assert is_binary(status.agent_session_id)
    refute Map.has_key?(status, :worker_pid)
  end

  test "session_status retains stopped and crashed terminal sessions", %{prehen_home: prehen_home} do
    assert {:ok, %{session_id: stopped_session_id}} =
             Surface.create_session(agent: "coder", prehen_home: prehen_home)

    assert :ok = Surface.stop_session(stopped_session_id)

    assert {:ok, stopped_status} = Surface.session_status(stopped_session_id)
    assert stopped_status.session_id == stopped_session_id
    assert stopped_status.status == :stopped
    assert stopped_status.agent_name == "coder"
    assert is_binary(stopped_status.agent_session_id)
    refute Map.has_key?(stopped_status, :worker_pid)

    assert {:ok, %{session_id: crashed_session_id}} =
             Surface.create_session(agent: "coder", prehen_home: prehen_home)

    assert {:ok, worker_pid} = SessionRegistry.fetch_worker(crashed_session_id)
    wrapper_pid = :sys.get_state(worker_pid).wrapper
    monitor_ref = Process.monitor(worker_pid)

    Process.exit(wrapper_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason}, 2_000

    assert {:ok, crashed_status} = Surface.session_status(crashed_session_id)
    assert crashed_status.session_id == crashed_session_id
    assert crashed_status.status == :crashed
    assert crashed_status.agent_name == "coder"
    assert is_binary(crashed_status.agent_session_id)
    refute Map.has_key?(crashed_status, :worker_pid)
  end

  test "run/2 on reused session correlates to its own request_id and returns complete trace", %{
    prehen_home: prehen_home
  } do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "correlated_agent", prehen_home: prehen_home)

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

  defp registry_state do
    profiles = [
      PiAgentFixture.profile("coder"),
      PiAgentFixture.profile("inspecting",
        label: "Inspecting",
        description: "Inspecting profile",
        implementation: "inspecting_impl",
        prompt_profile: "coder_default"
      ),
      PiAgentFixture.profile("correlated_agent",
        label: "Correlated Agent",
        description: "correlated_agent profile",
        implementation: "correlated_impl",
        prompt_profile: "correlated_default"
      ),
      PiAgentFixture.profile("slow_open",
        label: "Slow Open",
        description: "slow_open profile",
        implementation: "slow_open_impl",
        prompt_profile: "slow_default"
      )
    ]

    implementations = [
      PiAgentFixture.implementation("coder"),
      PiAgentFixture.implementation("inspecting", %{},
        name: "inspecting_impl",
        wrapper: InspectingWrapper
      ),
      %Implementation{
        name: "correlated_impl",
        command: "noop",
        args: [],
        env: %{},
        wrapper: CorrelatingWrapper
      },
      PiAgentFixture.implementation("slow_open", %{},
        name: "slow_open_impl",
        wrapper: SlowOpenWrapper
      )
    ]

    PiAgentFixture.registry_state(profiles, implementations)
  end

  defp write_profile_home!(prehen_home, profile_name) do
    profile_dir = profile_workspace(prehen_home, profile_name)
    File.mkdir_p!(profile_dir)
    File.write!(Path.join(profile_dir, "SOUL.md"), "SOUL for #{profile_name}.\n")
    File.write!(Path.join(profile_dir, "AGENTS.md"), "AGENTS for #{profile_name}.\n")
  end

  defp profile_workspace(prehen_home, profile_name) do
    Path.join([prehen_home, "profiles", profile_name])
  end

  defp tmp_prehen_home(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_surface_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
