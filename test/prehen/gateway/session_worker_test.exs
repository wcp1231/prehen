defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.Implementation
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Gateway.InboxProjection
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker

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

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)
    InboxProjection.reset()

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      InboxProjection.reset()
    end)

    :ok
  end

  test "forwards normalized output delta events through registry inbox projection and pubsub" do
    Phoenix.PubSub.subscribe(Prehen.PubSub, "session:gw_1")

    assert {:ok, %{worker_pid: pid, gateway_session_id: "gw_1"}} =
             SessionWorker.start_session(
               session_config(),
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
              agent_name: "fake_stdio",
              provider: "openai",
              model: "gpt-5",
              prompt_profile: "fake_default",
              status: :running,
              agent_session_id: agent_session_id
            }} = SessionRegistry.fetch("gw_1")

    assert is_binary(agent_session_id)

    assert_receive {:gateway_event, event}
    assert event.type == "session.output.delta"
    assert event.gateway_session_id == "gw_1"
    assert event.agent_session_id == agent_session_id
    assert event.agent == "fake_stdio"
    assert event.seq == 1

    assert event.payload == %{
             "agent_session_id" => agent_session_id,
             "message_id" => "msg_1",
             "text" => "hi"
           }

    assert_receive {:gateway_event, pubsub_event}
    assert pubsub_event.type == "session.output.delta"
    assert pubsub_event.gateway_session_id == "gw_1"

    assert {:ok, %{status: :idle, agent_name: "fake_stdio"}} =
             wait_until(fn ->
               case InboxProjection.fetch_session("gw_1") do
                 {:ok, %{status: :idle} = row} -> {:ok, row}
                 _ -> :retry
               end
             end)

    assert {:ok, history} = InboxProjection.fetch_history("gw_1")

    assert Enum.map(history, &Map.take(&1, [:kind, :message_id, :text])) == [
             %{kind: :user_message, message_id: "msg_1", text: "hi"},
             %{kind: :assistant_message, message_id: "msg_1", text: "hi"}
           ]
  end

  test "envelope normalizes explicit nil payload and metadata" do
    event =
      Envelope.build("session.output.delta", %{
        gateway_session_id: "gw_2",
        agent_session_id: "agent_gw_2",
        agent: "fake_stdio",
        seq: 1,
        payload: nil,
        metadata: nil
      })

    assert event.payload == %{}
    assert event.metadata == %{}
  end

  test "retains terminal registry metadata when wrapper startup fails" do
    assert {:error, :open_failed} =
             SessionWorker.start_session(
               session_config(
                 profile_name: "broken_stdio",
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
    assert session.agent_name == "broken_stdio"
    assert session.provider == "openai"
    assert session.model == "gpt-5"
    assert session.prompt_profile == "fake_default"
    assert session.workspace == "/tmp/prehen_worker_test"
    refute Map.has_key?(session, :agent_session_id)
  end

  defp session_config(overrides \\ []) do
    base = %SessionConfig{
      profile_name: "fake_stdio",
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "fake_default",
      workspace_policy: %{mode: "scoped"},
      implementation: implementation(),
      workspace: "/tmp/prehen_worker_test"
    }

    struct!(base, Enum.into(overrides, %{}))
  end

  defp implementation(overrides \\ []) do
    base = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_wrapper_agent.exs"],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.Passthrough
    }

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
