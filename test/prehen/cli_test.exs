defmodule Prehen.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Prehen.Client.Surface
  alias Prehen.TestSupport.PiAgentFixture

  setup do
    original = PiAgentFixture.replace_registry!(PiAgentFixture.registry_state("coder"))
    workspace = PiAgentFixture.workspace!("cli")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "cli run success path", %{workspace: workspace} do
    File.write!(Path.join(workspace, "a.txt"), "hello")

    output =
      capture_io(fn ->
        assert {:ok, %{answer: "echo:say hi", status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "say",
                   "hi",
                   "--agent",
                   "coder",
                   "--workspace",
                   workspace,
                   "--trace-json"
                 ])
      end)

    assert output =~ "Answer:"
    assert output =~ "echo:say hi"
  end

  test "cli run failure path for missing gateway session" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, %{status: :error, type: :runtime_failed}} =
                 Prehen.CLI.main([
                   "run",
                   "fail",
                   "--session-id",
                   "missing_gateway_session"
                 ])
      end)

    assert stderr =~ "Execution failed"
  end

  test "cli rejects removed --root-dir option with explicit message" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_args} = Prehen.CLI.main(["run", "task", "--root-dir", "."])
      end)

    assert stderr =~ "Invalid option: --root-dir (removed). Use --workspace PATH instead."
  end

  test "cli rejects removed --model option with explicit message" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_args} =
                 Prehen.CLI.main(["run", "task", "--model", "openai:gpt-5-mini"])
      end)

    assert stderr =~ "Invalid option: --model (removed). Use --agent NAME."
  end

  test "cli run supports --agent gateway execution path", %{workspace: workspace} do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "coder",
                   "--workspace",
                   workspace,
                   "hello"
                 ])
      end)

    assert output =~ "Answer:"
    assert output =~ "echo:hello"
  end

  test "trace_json outputs typed envelope schema without legacy fields", %{workspace: workspace} do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "coder",
                   "--workspace",
                   workspace,
                   "hello",
                   "--trace-json"
                 ])
      end)

    [_, trace_and_answer] = String.split(output, "Trace:\n", parts: 2)
    [trace_json, _answer] = String.split(trace_and_answer, "\nAnswer:\n", parts: 2)
    trace = Jason.decode!(String.trim(trace_json))

    assert is_list(trace) and trace != []

    Enum.each(trace, fn event ->
      assert is_binary(event["type"])
      assert is_integer(event["at_ms"])
      assert event["source"] == "prehen.gateway"
      assert event["schema_version"] == 2
      refute Map.has_key?(event, "event")
    end)

    assert Enum.any?(trace, fn event -> event["type"] == "agent.started" end)
    assert Enum.any?(trace, fn event -> event["type"] == "session.output.delta" end)
  end

  test "cli run supports --session-id on active gateway session with continuous trace", %{
    workspace: workspace
  } do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "coder", workspace: workspace)

    on_exit(fn -> Surface.stop_session(session_id) end)

    _first_output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "cli first",
                   "--session-id",
                   session_id,
                   "--trace-json"
                 ])
      end)

    second_output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "cli second",
                   "--session-id",
                   session_id,
                   "--trace-json"
                 ])
      end)

    second_trace = decode_trace_json(second_output)

    assert Enum.any?(second_trace, fn event ->
             event["type"] == "session.output.delta"
           end)

    assert Enum.all?(second_trace, fn event ->
             event["session_id"] == session_id
           end)
  end

  defp decode_trace_json(output) do
    [_, trace_and_answer] = String.split(output, "Trace:\n", parts: 2)
    [trace_json, _answer] = String.split(trace_and_answer, "\nAnswer:\n", parts: 2)
    Jason.decode!(String.trim(trace_json))
  end
end
