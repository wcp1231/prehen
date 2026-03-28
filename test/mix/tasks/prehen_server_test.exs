defmodule Mix.Tasks.Prehen.ServerTest do
  use ExUnit.Case, async: false

  test "starts the app and announces the inbox entrypoint" do
    parent = self()

    assert :ok =
             Mix.Tasks.Prehen.Server.run([],
               start_task: fn task, args ->
                 send(parent, {:start_task, task, args})
                 :ok
               end,
               announce: fn message ->
                 send(parent, {:announce, message})
                 :ok
               end,
               wait: fn ->
                 send(parent, :wait_forever)
                 :ok
               end
             )

    assert_receive {:start_task, "app.start", []}
    assert_receive {:announce, "Prehen server listening on http://localhost:4000/inbox"}
    assert_receive :wait_forever
  end

  test "rejects unexpected arguments" do
    assert_raise Mix.Error, ~r/mix prehen\.server does not accept arguments/, fn ->
      Mix.Tasks.Prehen.Server.run(["--port", "4001"],
        start_task: fn _task, _args -> :ok end,
        announce: fn _message -> :ok end,
        wait: fn -> :ok end
      )
    end
  end
end
