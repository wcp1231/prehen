defmodule Prehen.Agents.Wrappers.ExecutableHostTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Wrappers.ExecutableHost

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
end
