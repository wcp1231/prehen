defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Envelope
  alias Prehen.Agents.Profile
  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker

  defmodule BrokenOpenTransport do
    def start_link(opts) do
      profile = Keyword.fetch!(opts, :profile)
      test_pid = profile.metadata.test_pid
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:broken_transport_started, pid})
      {:ok, pid}
    end

    def open_session(_transport, _attrs), do: {:error, :open_failed}
    def recv_frame(_transport, _timeout), do: {:error, :closed}
    def send_message(_transport, _attrs), do: :ok
    def send_control(_transport, _attrs), do: :ok

    def stop(transport) when is_pid(transport) do
      if Process.alive?(transport), do: Process.exit(transport, :kill)
      :ok
    end
  end

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)
    original_state = :sys.get_state(Prehen.Agents.Registry)

    fake_profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    :sys.replace_state(Prehen.Agents.Registry, fn _ ->
      %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
    end)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      :sys.replace_state(Prehen.Agents.Registry, fn _ -> original_state end)
    end)

    :ok
  end

  test "forwards normalized output delta events with gateway session metadata" do
    assert {:ok, pid} =
             SessionWorker.start_link(
               gateway_session_id: "gw_1",
               agent_name: "fake_stdio",
               test_pid: self()
             )

    assert :ok =
             SessionWorker.submit_message(pid, %{
               role: "user",
               parts: [%{type: "text", text: "hi"}]
             })

    assert {:ok, %{agent_session_id: "agent_gw_1", status: :running}} =
             SessionRegistry.fetch("gw_1")

    assert_receive {:gateway_event, event}
    assert event.type == "session.output.delta"
    assert event.gateway_session_id == "gw_1"
    assert event.agent_session_id == "agent_gw_1"
    assert event.agent == "fake_stdio"
    assert event.seq == 1

    assert event.payload == %{
             "agent_session_id" => "agent_gw_1",
             "message_id" => "message_1",
             "text" => "hi"
           }
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

  test "retains terminal registry metadata when worker terminates after transport failure" do
    assert {:ok, pid} =
             SessionWorker.start_link(
               gateway_session_id: "gw_cleanup",
               agent_name: "fake_stdio",
               test_pid: self()
             )

    assert {:ok, %{status: :attached}} = SessionRegistry.fetch("gw_cleanup")

    monitor_ref = Process.monitor(pid)
    transport_pid = :sys.get_state(pid).transport
    Process.exit(transport_pid, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 2_000

    assert {:ok, session} = SessionRegistry.fetch("gw_cleanup")
    assert session.status == :crashed
    assert session.worker_pid == nil
    assert session.agent_name == "fake_stdio"
    assert session.agent_session_id == "agent_gw_cleanup"
  end

  test "stops started transport when init fails after transport start" do
    broken_profile = %Profile{
      name: "broken_stdio",
      command: ["noop"],
      transport: BrokenOpenTransport,
      metadata: %{test_pid: self()}
    }

    :sys.replace_state(Prehen.Agents.Registry, fn _ ->
      %{ordered: [broken_profile], by_name: %{"broken_stdio" => broken_profile}}
    end)

    assert {:error, :open_failed} =
             SessionWorker.start_link(
               gateway_session_id: "gw_broken",
               agent_name: "broken_stdio",
               test_pid: self()
             )

    assert_receive {:broken_transport_started, transport_pid}, 1_000
    ref = Process.monitor(transport_pid)
    assert_receive {:DOWN, ^ref, :process, ^transport_pid, _reason}, 1_000
  end
end
