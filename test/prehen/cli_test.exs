defmodule Prehen.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "cli run success path" do
    workspace =
      Path.join(System.tmp_dir!(), "prehen_cli_ok_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), "hello")

    on_exit(fn -> File.rm_rf(workspace) end)

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
                     "--workspace",
                     workspace
                   ] ++ ["--trace-json"]
                 )
      end)

    assert output =~ "Answer:"
    assert output =~ "CLI done"
  end

  test "cli run failure path" do
    workspace =
      Path.join(System.tmp_dir!(), "prehen_cli_fail_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

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
                   "--workspace",
                   workspace,
                   "--max-steps",
                   "1"
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

  test "cli run supports --agent template execution path" do
    workspace = Application.fetch_env!(:prehen, :workspace_dir)
    config_dir = Path.join([workspace, ".prehen", "config"])
    File.mkdir_p!(config_dir)

    providers_path = Path.join(config_dir, "providers.yaml")
    agents_path = Path.join(config_dir, "agents.yaml")
    secrets_path = Path.join(config_dir, "secrets.yaml")
    backups = backup_files([providers_path, agents_path, secrets_path])

    File.write!(
      providers_path,
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
      """
    )

    File.write!(
      agents_path,
      """
      agents:
        coder_cli:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
          capability_packs: [local_fs]
      """
    )

    File.write!(
      secrets_path,
      """
      secrets:
        providers:
          openai_official:
            api_key: sk-local
      """
    )

    Application.put_env(:prehen, :agent_backend, Prehen.Agent.Backends.JidoAI)
    Application.put_env(:prehen, :session_adapter, Prehen.Test.FakeSessionAdapter)

    on_exit(fn ->
      Application.delete_env(:prehen, :agent_backend)
      Application.delete_env(:prehen, :session_adapter)
      restore_files(backups)
    end)

    output =
      capture_io(fn ->
        assert {:ok, %{status: :ok}} =
                 Prehen.CLI.main([
                   "run",
                   "--agent",
                   "coder_cli",
                   "hello"
                 ])
      end)

    assert output =~ "Answer:"
    assert output =~ "answer:hello"
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

  defp backup_files(paths) do
    Enum.map(paths, fn path ->
      if File.exists?(path) do
        {:ok, content} = File.read(path)
        {path, {:existing, content}}
      else
        {path, :missing}
      end
    end)
  end

  defp restore_files(backups) do
    Enum.each(backups, fn
      {path, {:existing, content}} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)

      {path, :missing} ->
        File.rm(path)
    end)
  end
end
