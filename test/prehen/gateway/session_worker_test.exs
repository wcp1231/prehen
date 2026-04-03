defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Gateway.InboxProjection
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker
  alias Prehen.MCP.SessionAuth
  alias Prehen.TestSupport.PiAgentFixture

  defmodule BrokenOpenWrapper do
    use GenServer

    @behaviour Wrapper

    @impl Wrapper
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl Wrapper
    def open_session(wrapper, attrs), do: GenServer.call(wrapper, {:open_session, attrs})

    @impl Wrapper
    def send_message(_wrapper, _attrs), do: :ok

    @impl Wrapper
    def send_control(_wrapper, _attrs), do: :ok

    @impl Wrapper
    def recv_event(_wrapper, _timeout), do: {:error, :closed}

    @impl Wrapper
    def support_check(_session_config), do: :ok

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(opts) do
      test_pid = Keyword.get(opts, :test_pid)
      if is_pid(test_pid), do: send(test_pid, {:broken_wrapper_started, self()})
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call({:open_session, _attrs}, _from, state) do
      {:stop, :normal, {:error, :open_failed}, state}
    end
  end

  defmodule OpenSessionCaptureWrapper do
    use GenServer

    @behaviour Wrapper

    @impl Wrapper
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl Wrapper
    def open_session(wrapper, attrs), do: GenServer.call(wrapper, {:open_session, attrs})

    @impl Wrapper
    def send_message(_wrapper, _attrs), do: :ok

    @impl Wrapper
    def send_control(_wrapper, _attrs), do: :ok

    @impl Wrapper
    def recv_event(_wrapper, _timeout), do: {:error, :closed}

    @impl Wrapper
    def support_check(_session_config), do: :ok

    @impl Wrapper
    def stop(wrapper), do: GenServer.stop(wrapper)

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.get(opts, :test_pid)}}
    end

    @impl true
    def handle_call({:open_session, attrs}, _from, state) do
      if is_pid(state.test_pid), do: send(state.test_pid, {:captured_open_session, attrs})
      {:reply, {:ok, %{agent_session_id: "captured_session"}}, state}
    end
  end

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)
    InboxProjection.reset()
    workspace = PiAgentFixture.workspace!("session_worker")

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      InboxProjection.reset()
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "forwards normalized output delta events through registry inbox projection and pubsub", %{
    workspace: workspace
  } do
    Phoenix.PubSub.subscribe(Prehen.PubSub, "session:gw_1")

    assert {:ok, %{worker_pid: pid, gateway_session_id: "gw_1"}} =
             SessionWorker.start_session(
               session_config(workspace),
               gateway_session_id: "gw_1",
               test_pid: self()
             )

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, pid)
      end
    end)

    assert :ok =
             SessionWorker.submit_message(pid, %{
               role: "user",
               message_id: "msg_1",
               parts: [%{type: "text", text: "hi"}]
             })

    assert {:ok,
            %{
              agent_name: "coder",
              provider: "openai",
              model: "gpt-5",
              prompt_profile: "coder_default",
              status: :running,
              agent_session_id: agent_session_id
            }} = SessionRegistry.fetch("gw_1")

    assert is_binary(agent_session_id)

    assert_receive {:gateway_event, event}, 1_000
    assert event.type == "session.output.delta"
    assert event.gateway_session_id == "gw_1"
    assert event.agent_session_id == agent_session_id
    assert event.agent == "coder"
    assert event.seq == 1

    assert event.payload == %{
             "message_id" => "msg_1",
             "text" => "echo:hi"
           }

    assert_receive {:gateway_event, pubsub_event}, 1_000
    assert pubsub_event.type == "session.output.delta"
    assert pubsub_event.gateway_session_id == "gw_1"

    assert {:ok, %{status: :idle, agent_name: "coder"}} =
             wait_until(fn ->
               case InboxProjection.fetch_session("gw_1") do
                 {:ok, %{status: :idle} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    assert {:ok, history} = InboxProjection.fetch_history("gw_1")

    assert Enum.map(history, &Map.take(&1, [:kind, :message_id, :text])) == [
             %{kind: :user_message, message_id: "msg_1", text: "hi"},
             %{kind: :assistant_message, message_id: "msg_1", text: "echo:hi"}
           ]
  end

  test "envelope normalizes explicit nil payload and metadata" do
    event =
      Envelope.build("session.output.delta", %{
        gateway_session_id: "gw_2",
        agent_session_id: "agent_gw_2",
        agent: "coder",
        seq: 1,
        payload: nil,
        metadata: nil
      })

    assert event.payload == %{}
    assert event.metadata == %{}
  end

  test "retains terminal registry metadata when wrapper startup fails", %{workspace: workspace} do
    assert {:error, :open_failed} =
             SessionWorker.start_session(
               session_config(
                 workspace,
                 profile_name: "broken_coder",
                 implementation:
                   implementation(
                     name: "broken_impl",
                     command: "noop",
                     args: [],
                     wrapper: BrokenOpenWrapper
                   )
               ),
               gateway_session_id: "gw_broken",
               test_pid: self()
             )

    assert_receive {:broken_wrapper_started, wrapper_pid}, 1_000
    ref = Process.monitor(wrapper_pid)
    assert_receive {:DOWN, ^ref, :process, ^wrapper_pid, _reason}, 1_000

    assert {:ok, session} = SessionRegistry.fetch("gw_broken")
    assert session.status == :crashed
    assert session.worker_pid == nil
    assert session.agent_name == "broken_coder"
    assert session.provider == "openai"
    assert session.model == "gpt-5"
    assert session.prompt_profile == "coder_default"
    assert session.workspace == workspace
    refute Map.has_key?(session, :agent_session_id)
  end

  test "normal stop removes the live worker route while retaining terminal metadata", %{
    workspace: workspace
  } do
    assert {:ok, %{worker_pid: pid, gateway_session_id: "gw_stop"}} =
             SessionWorker.start_session(
               session_config(workspace),
               gateway_session_id: "gw_stop",
               test_pid: self()
             )

    monitor_ref = Process.monitor(pid)

    assert {:ok, ^pid} = SessionRegistry.fetch_worker("gw_stop")
    assert :ok = DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000

    assert {:ok, %{status: :stopped, worker_pid: nil} = session} =
             wait_until(fn ->
               case SessionRegistry.fetch("gw_stop") do
                 {:ok, %{status: :stopped, worker_pid: nil} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    assert session.agent_name == "coder"
    assert is_binary(session.agent_session_id)
    assert {:error, :not_found} = SessionRegistry.fetch_worker("gw_stop")
  end

  test "session lifecycle recovers MCP auth after auth server restart and tears it down on stop", %{
    workspace: workspace
  } do
    assert {:ok, %{worker_pid: pid, gateway_session_id: "gw_mcp"}} =
             SessionWorker.start_session(
               session_config(workspace),
               gateway_session_id: "gw_mcp",
               test_pid: self()
             )

    state = :sys.get_state(pid)
    token = Map.fetch!(state, :mcp_token)

    assert {:ok, %{session_id: "gw_mcp", profile_id: "coder", capabilities: capabilities}} =
             SessionAuth.lookup(token)

    assert Enum.sort(capabilities) == ["skills.load", "skills.search"]

    auth_pid = Process.whereis(SessionAuth)
    auth_ref = Process.monitor(auth_pid)
    Process.exit(auth_pid, :kill)
    assert_receive {:DOWN, ^auth_ref, :process, ^auth_pid, :killed}, 1_000

    assert {:ok, restarted_auth_pid} =
             wait_until(fn ->
               case Process.whereis(SessionAuth) do
                 nil -> :retry
                 new_pid when is_pid(new_pid) and new_pid != auth_pid -> {:ok, new_pid}
                 _ -> :retry
               end
             end)

    assert Process.alive?(restarted_auth_pid)

    assert {:ok, %{session_id: "gw_mcp", profile_id: "coder", capabilities: recovered_capabilities}} =
             SessionAuth.lookup(token)

    assert Enum.sort(recovered_capabilities) == ["skills.load", "skills.search"]

    monitor_ref = Process.monitor(pid)
    assert :ok = DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000

    assert {:error, :not_found} = SessionAuth.lookup(token)
  end

  test "passes session-scoped MCP metadata into wrapper open_session attrs", %{workspace: workspace} do
    assert {:ok, %{worker_pid: pid, gateway_session_id: "gw_capture"}} =
             SessionWorker.start_session(
               session_config(
                 workspace,
                 implementation:
                   implementation(
                     name: "capture_impl",
                     command: "capture",
                     args: [],
                     wrapper: OpenSessionCaptureWrapper
                   )
               ),
               gateway_session_id: "gw_capture",
               test_pid: self()
             )

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Prehen.Gateway.SessionWorkerSupervisor, pid)
      end
    end)

    assert_receive {:captured_open_session, attrs}, 1_000
    assert attrs.gateway_session_id == "gw_capture"
    assert attrs.profile_name == "coder"
    assert attrs.agent == "coder"
    assert is_binary(attrs.mcp_token) and attrs.mcp_token != ""
    assert is_binary(attrs.mcp_url) and String.ends_with?(attrs.mcp_url, "/mcp")
  end

  defp session_config(workspace, overrides \\ []) do
    base = %SessionConfig{
      profile_name: "coder",
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"},
      implementation: implementation(),
      workspace: workspace,
      system_prompt: "PREHEN GLOBAL\n\nSOUL\n\nAGENTS"
    }

    struct!(base, Enum.into(overrides, %{}))
  end

  defp implementation(overrides \\ []) do
    base = PiAgentFixture.implementation("coder", %{}, name: "coder_impl")

    struct!(base, Enum.into(overrides, %{}))
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      :retry ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: {:error, :timeout}
end
