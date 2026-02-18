defmodule PrehenTest do
  use ExUnit.Case
  doctest Prehen

  test "greets the world" do
    assert Prehen.hello() == :world
  end
end
