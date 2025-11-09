defmodule EtherCATTest do
  use ExUnit.Case
  doctest EtherCAT

  test "module is defined" do
    assert Code.ensure_loaded?(EtherCAT)
  end

  test "exposes core API functions" do
    # Master operations
    assert function_exported?(EtherCAT, :open, 1)
    assert function_exported?(EtherCAT, :connect, 1)
    assert function_exported?(EtherCAT, :list_slaves, 1)
    assert function_exported?(EtherCAT, :start_cyclic, 1)
    assert function_exported?(EtherCAT, :activate, 1)
    assert function_exported?(EtherCAT, :create_domain, 3)

    # Slave operations
    assert function_exported?(EtherCAT, :configure_slave, 2)
    assert function_exported?(EtherCAT, :list_pdos, 1)
    assert function_exported?(EtherCAT, :register_pdos, 3)
    assert function_exported?(EtherCAT, :register_all_pdos, 2)

    # I/O operations
    assert function_exported?(EtherCAT, :read, 2)
    assert function_exported?(EtherCAT, :write, 3)
    assert function_exported?(EtherCAT, :watch, 3)
  end
end
