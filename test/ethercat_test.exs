defmodule EtherCATTest do
  use ExUnit.Case
  doctest EtherCAT

  test "module is defined" do
    assert Code.ensure_loaded?(EtherCAT)
  end

  test "exposes core API functions" do
    # Master operations
    assert function_exported?(EtherCAT, :open, 1)
    assert function_exported?(EtherCAT, :close, 1)
    assert function_exported?(EtherCAT, :start_cyclic, 1)
    assert function_exported?(EtherCAT, :create_domain, 3)

    # Slave operations
    assert function_exported?(EtherCAT, :configure_slave, 3)
    assert function_exported?(EtherCAT, :register_pdos, 3)
    assert function_exported?(EtherCAT, :register_pdos, 4)

    # I/O operations (now use PDO handles)
    assert function_exported?(EtherCAT, :read, 1)
    assert function_exported?(EtherCAT, :write, 2)
    assert function_exported?(EtherCAT, :watch, 1)
    assert function_exported?(EtherCAT, :unwatch, 1)
  end
end
