defmodule Prehen.Agents.Wrappers.ExecutableHostTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Wrappers.ExecutableHost

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "prehen_executable_host_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "emits stdout and stderr as distinct host events" do
    assert {:ok, host} =
             ExecutableHost.start_link(
               owner: self(),
               command: "python3",
               args: ["-c", "import sys; sys.stdout.write('out'); sys.stderr.write('err')"]
             )

    events =
      Enum.map(1..2, fn _index ->
        receive do
          {:executable_host, ^host, {stream, data}} when stream in [:stdout, :stderr] ->
            {stream, data}
        after
          1_000 -> flunk("expected stdout/stderr host event")
        end
      end)

    assert {:stdout, "out"} in events
    assert {:stderr, "err"} in events
    assert_receive {:executable_host, ^host, {:exit_status, 0}}, 1_000
  end

  test "forwards stdin to the child after relay bootstrap" do
    assert {:ok, host} =
             ExecutableHost.start_link(
               owner: self(),
               command: "python3",
               args: [
                 "-c",
                 "import sys; sys.stdout.write(sys.stdin.readline()); sys.stdout.flush()"
               ]
             )

    assert :ok = ExecutableHost.write(host, "hello from host\n")
    assert_receive {:executable_host, ^host, {:stdout, "hello from host\n"}}, 1_000
    assert_receive {:executable_host, ^host, {:exit_status, 0}}, 1_000
  end

  test "rejects slash paths that are not executable", %{tmp_dir: tmp_dir} do
    script_path = Path.join(tmp_dir, "not_executable.py")
    File.write!(script_path, "print('hi')\n")

    assert {:error, {:command_not_executable, ^script_path}} =
             ExecutableHost.support_check(%{command: script_path})

    assert {:error, {:command_not_executable, ^script_path}} =
             ExecutableHost.start_link(owner: self(), command: script_path)
  end

  test "emits structured stderr and exit events for child spawn os errors", %{tmp_dir: tmp_dir} do
    script_path = Path.join(tmp_dir, "bad_exec")
    File.write!(script_path, "not a real executable\n")
    File.chmod!(script_path, 0o755)

    assert {:ok, host} = ExecutableHost.start_link(owner: self(), command: script_path)

    assert_receive {:executable_host, ^host, {:stderr, stderr}}, 1_000
    assert stderr =~ script_path
    assert_receive {:executable_host, ^host, {:exit_status, 126}}, 1_000
  end
end
