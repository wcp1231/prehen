defmodule Prehen.HomeTest do
  use ExUnit.Case, async: false

  alias Prehen.Home

  setup do
    original_home = System.get_env("PREHEN_HOME")

    on_exit(fn ->
      case original_home do
        nil -> System.delete_env("PREHEN_HOME")
        value -> System.put_env("PREHEN_HOME", value)
      end
    end)

    :ok
  end

  test "root defaults to ~/.prehen" do
    System.delete_env("PREHEN_HOME")

    assert Home.root() == Path.join(System.user_home!(), ".prehen")
    assert Home.path("config.yaml") == Path.join(System.user_home!(), ".prehen/config.yaml")

    assert Home.path(["profiles", "coder"]) ==
             Path.join(System.user_home!(), ".prehen/profiles/coder")
  end

  test "root respects PREHEN_HOME override" do
    tmp = Path.join(System.tmp_dir!(), "prehen_home_test_#{System.unique_integer([:positive])}")
    System.put_env("PREHEN_HOME", tmp)

    assert Home.root() == tmp
    assert Home.path("config.yaml") == Path.join(tmp, "config.yaml")
  end
end
