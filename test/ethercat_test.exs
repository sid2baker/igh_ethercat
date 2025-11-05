defmodule EtherCATTest do
  use ExUnit.Case
  doctest EtherCAT

  test "greets the world" do
    assert EtherCAT.hello() == :world
  end
end
