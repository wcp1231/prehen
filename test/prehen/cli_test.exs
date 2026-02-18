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
        assert {:error, %{reason: :unknown_provider}} =
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
end
