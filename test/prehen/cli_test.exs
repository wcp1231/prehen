defmodule Prehen.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Prehen.Client.Surface
  alias Prehen.TestSupport.PiAgentFixture

  setup do
    original = PiAgentFixture.replace_registry!(PiAgentFixture.registry_state("coder"))
    prehen_home = tmp_prehen_home("cli")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    System.put_env("PREHEN_HOME", prehen_home)
    write_profile_home!(prehen_home, "coder")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "cli run success path" do
    output =
      capture_io(fn ->
        assert {:ok, %{answer: "echo:say hi", status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "say",
                   "hi",
                   "--agent",
                   "coder",
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

    assert stderr =~
             "Invalid option: --root-dir (removed). Workspace is fixed by the selected profile."
  end

  test "cli rejects removed --workspace option with explicit message" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_args} =
                 Prehen.CLI.main(["run", "task", "--workspace", "/tmp/workspace"])
      end)

    assert stderr =~
             "Invalid option: --workspace (removed). Workspace is fixed by the selected profile."
  end

  test "cli rejects removed --model option with explicit message" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_args} =
                 Prehen.CLI.main(["run", "task", "--model", "openai:gpt-5-mini"])
      end)

    assert stderr =~ "Invalid option: --model (removed). Use --agent NAME."
  end

  test "cli run supports --agent gateway execution path" do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "coder",
                   "hello"
                 ])
      end)

    assert output =~ "Answer:"
    assert output =~ "echo:hello"
  end

  test "trace_json outputs typed envelope schema without legacy fields" do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "coder",
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

  test "cli run supports --session-id on active gateway session with continuous trace" do
    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "coder")

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

  defp write_profile_home!(prehen_home, profile_name) do
    profile_dir = Path.join([prehen_home, "profiles", profile_name])
    File.mkdir_p!(profile_dir)
    File.write!(Path.join(profile_dir, "SOUL.md"), "SOUL for #{profile_name}.\n")
    File.write!(Path.join(profile_dir, "AGENTS.md"), "AGENTS for #{profile_name}.\n")
  end

  defp tmp_prehen_home(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_cli_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
