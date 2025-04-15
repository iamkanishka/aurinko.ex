defmodule AurinkoTest do
  use ExUnit.Case
  doctest Aurinko

  test "greets the world" do
    assert Aurinko.hello() == :world
  end
end
