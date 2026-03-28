defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case, async: false

  defmodule CorrelatingTransport do
    use GenServer

    alias Prehen.Agents.Transport

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def open_session(transport, _attrs), do: GenServer.call(transport, :open_session)
    def send_message(transport, attrs), do: GenServer.call(transport, {:send_message, attrs})
    def recv_frame(transport, timeout), do: Transport.recv_frame(transport, timeout)
    def send_control(_transport, _attrs), do: :ok
    def stop(transport), do: GenServer.stop(transport)

    @impl true
    def init(opts) do
      gateway_session_id = Keyword.fetch!(opts, :gateway_session_id)
      {:ok, %{gateway_session_id: gateway_session_id, queue: :queue.new(), recv_from: nil}}
    end

    @impl true
    def handle_call(:open_session, _from, state) do
      {:reply, {:ok, %{agent_session_id: "agent_#{state.gateway_session_id}"}}, state}
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

    def handle_call({:recv_frame, _timeout}, from, state) do
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
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    correlated_profile = %Profile{
      name: "correlated_agent",
      command: ["noop"],
      transport: CorrelatingTransport
    }

    :sys.replace_state(registry_pid, fn _state ->
      %{
        ordered: [fake_profile, correlated_profile],
        by_name: %{
          "fake_stdio" => fake_profile,
          "correlated_agent" => correlated_profile
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
  end

  test "session_status retains stopped and crashed terminal sessions" do
    assert {:ok, %{session_id: stopped_session_id}} = Surface.create_session(agent: "fake_stdio")
    assert :ok = Surface.stop_session(stopped_session_id)

    assert {:ok, stopped_status} = Surface.session_status(stopped_session_id)
    assert stopped_status.session_id == stopped_session_id
    assert stopped_status.status == :stopped
    assert stopped_status.agent_name == "fake_stdio"
    assert is_binary(stopped_status.agent_session_id)

    assert {:ok, %{session_id: crashed_session_id}} = Surface.create_session(agent: "fake_stdio")
    assert {:ok, worker_pid} = SessionRegistry.fetch_worker(crashed_session_id)
    transport_pid = :sys.get_state(worker_pid).transport
    monitor_ref = Process.monitor(worker_pid)

    Process.exit(transport_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason}, 2_000

    assert {:ok, crashed_status} = Surface.session_status(crashed_session_id)
    assert crashed_status.session_id == crashed_session_id
    assert crashed_status.status == :crashed
    assert crashed_status.agent_name == "fake_stdio"
    assert is_binary(crashed_status.agent_session_id)
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
