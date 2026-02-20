defmodule Prehen.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "cli run success path" do
    root = Path.join(System.tmp_dir!(), "prehen_cli_ok_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "hello")

    on_exit(fn -> File.rm_rf(root) end)

    Prehen.Test.MockBackend.set_results([
      {:ok, %{status: :ok, answer: "CLI done", trace: []}}
    ])

    Application.put_env(:prehen, :agent_backend, Prehen.Test.MockBackend)
    on_exit(fn -> Application.delete_env(:prehen, :agent_backend) end)

    output =
      capture_io(fn ->
        assert {:ok, %{answer: "CLI done"}} =
                 Prehen.CLI.main(
                   [
                     "run",
                     "say",
                     "hi",
                     "--root-dir",
                     root
                   ] ++ ["--trace-json"]
                 )
      end)

    assert output =~ "Answer:"
    assert output =~ "CLI done"
  end

  test "cli run failure path" do
    root = Path.join(System.tmp_dir!(), "prehen_cli_fail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    Prehen.Test.MockBackend.set_results([
      {:error, %{status: :error, reason: :unknown_provider, trace: []}}
    ])

    Application.put_env(:prehen, :agent_backend, Prehen.Test.MockBackend)
    on_exit(fn -> Application.delete_env(:prehen, :agent_backend) end)

    stderr =
      capture_io(:stderr, fn ->
        assert {:error,
                %{status: :error, type: :runtime_failed, reason: %{reason: :unknown_provider}}} =
                 Prehen.CLI.main([
                   "run",
                   "fail",
                   "--root-dir",
                   root,
                   "--max-steps",
                   "1"
                 ])
      end)

    assert stderr =~ "Execution failed"
  end

  test "trace_json outputs typed envelope schema without legacy fields" do
    Application.put_env(:prehen, :agent_backend, Prehen.Agent.Backends.JidoAI)
    Application.put_env(:prehen, :session_adapter, Prehen.Test.FakeSessionAdapter)

    on_exit(fn ->
      Application.delete_env(:prehen, :agent_backend)
      Application.delete_env(:prehen, :session_adapter)
    end)

    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} = Prehen.CLI.main(["run", "hello", "--trace-json"])
      end)

    [_, trace_and_answer] = String.split(output, "Trace:\n", parts: 2)
    [trace_json, _answer] = String.split(trace_and_answer, "\nAnswer:\n", parts: 2)
    trace = Jason.decode!(String.trim(trace_json))

    assert is_list(trace) and trace != []

    Enum.each(trace, fn event ->
      assert is_binary(event["type"])
      assert is_integer(event["at_ms"])
      assert event["source"] == "prehen.session"
      assert event["schema_version"] == 2
      refute Map.has_key?(event, "event")
    end)
  end

  test "cli run supports --session-id resume with continuous trace" do
    Application.put_env(:prehen, :agent_backend, Prehen.Agent.Backends.JidoAI)
    Application.put_env(:prehen, :session_adapter, Prehen.Test.FakeSessionAdapter)

    on_exit(fn ->
      Application.delete_env(:prehen, :agent_backend)
      Application.delete_env(:prehen, :session_adapter)
    end)

    first_output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} = Prehen.CLI.main(["run", "cli first", "--trace-json"])
      end)

    first_trace = decode_trace_json(first_output)
    session_id = first_trace |> hd() |> Map.fetch!("session_id")

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

    assert Enum.any?(second_trace, fn event -> event["type"] == "ai.session.recovered" end)

    assert Enum.any?(second_trace, fn event ->
             event["type"] == "ai.session.turn.started" and event["turn_id"] == 2
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
