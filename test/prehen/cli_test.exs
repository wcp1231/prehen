defmodule Prehen.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface

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

    fake_implementation = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_stdio_agent.exs"],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.Passthrough
    }

    :sys.replace_state(registry_pid, fn _state ->
      %{
        ordered: [fake_profile],
        by_name: %{"fake_stdio" => fake_profile},
        supported_ordered: [fake_profile],
        supported_by_name: %{"fake_stdio" => fake_profile},
        implementations_ordered: [fake_implementation],
        implementations_by_name: %{"fake_stdio_impl" => fake_implementation}
      }
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _state -> original end)
    end)

    :ok
  end

  test "cli run success path" do
    workspace =
      Path.join(System.tmp_dir!(), "prehen_cli_ok_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), "hello")

    on_exit(fn -> File.rm_rf(workspace) end)

    output =
      capture_io(fn ->
        assert {:ok, %{answer: "hi", status: :ok}} =
                 Prehen.CLI.main(
                   [
                     "run",
                     "say",
                     "hi",
                     "--agent",
                     "fake_stdio",
                     "--workspace",
                     workspace
                   ] ++ ["--trace-json"]
                 )
      end)

    assert output =~ "Answer:"
    assert output =~ "hi"
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

  test "cli run supports --agent gateway execution path" do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "fake_stdio",
                   "hello"
                 ])
      end)

    assert output =~ "Answer:"
    assert output =~ "hi"
  end

  test "trace_json outputs typed envelope schema without legacy fields" do
    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main(["run", "--agent", "fake_stdio", "hello", "--trace-json"])
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
    assert {:ok, %{session_id: session_id}} = Surface.create_session(agent: "fake_stdio")
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
