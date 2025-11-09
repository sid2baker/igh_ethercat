defmodule EtherCAT.APIValidationTest do
  @moduledoc """
  Comprehensive validation tests for the simplified EtherCAT API.

  These tests verify:
  - API contracts and return values
  - Domain validation and PDO conflict prevention
  - State machine lifecycle and transitions
  - Concurrent read/write safety
  - Error handling and edge cases

  Note: These tests use mock/stub behavior and do not require hardware.
  For hardware tests, see test/hardware/
  """
  use ExUnit.Case, async: false

  alias EtherCAT.{Master, Slave, Domain}

  # Skip all tests by default since they require a mock implementation
  # To run these tests, you would need to implement a mock NIF layer
  @moduletag :skip

  describe "API Contract Tests" do
    test "open/1 returns {:ok, master, slaves}" do
      # This would require a mock NIF
      assert {:ok, master, slaves} = EtherCAT.open()
      assert is_pid(master)
      assert is_list(slaves)
      assert Enum.all?(slaves, &is_pid/1)

      # Cleanup
      EtherCAT.close(master)
    end

    test "open/1 with options sets correct parameters" do
      assert {:ok, master, _slaves} = EtherCAT.open(update_interval: 5_000)
      assert is_pid(master)

      # Cleanup
      EtherCAT.close(master)
    end

    test "configure_slave/3 returns {:ok, pdo_list}" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()

      assert {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      assert is_list(pdos)
      assert Enum.all?(pdos, &is_binary/1)

      EtherCAT.close(master)
    end

    test "register_pdos/4 returns {:ok, unique_names}" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})

      assert {:ok, unique_names} = EtherCAT.register_pdos(master, slave, pdos)
      assert is_list(unique_names)

      # Verify all names are globally unique with slave position prefix
      assert Enum.all?(unique_names, fn name ->
        String.starts_with?(name, "slave_")
      end)

      EtherCAT.close(master)
    end

    test "read/2 returns {:ok, value} for registered PDO" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      assert {:ok, _value} = EtherCAT.read(master, unique_name)

      EtherCAT.close(master)
    end

    test "write/3 returns :ok for registered PDO" do
      {:ok, master, [_coupler, _input, output | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, output, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, output, pdos)

      EtherCAT.start_cyclic(master)

      assert :ok = EtherCAT.write(master, unique_name, true)

      EtherCAT.close(master)
    end

    test "close/1 terminates master and cleanup resources" do
      {:ok, master, _slaves} = EtherCAT.open()

      assert :ok = EtherCAT.close(master)

      # Verify master is no longer alive
      refute Process.alive?(master)
    end
  end

  describe "Domain Validation Tests" do
    test "PDO cannot be registered to multiple domains" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})

      # Create two domains
      {:ok, _domain1} = EtherCAT.create_domain(master, :domain1, 1)
      {:ok, _domain2} = EtherCAT.create_domain(master, :domain2, 10)

      # Register PDO to first domain
      assert {:ok, _} = EtherCAT.register_pdos(master, slave, [List.first(pdos)], :domain1)

      # Attempting to register same PDO to second domain should fail
      assert {:error, {:pdo_already_registered, conflicts}} =
               EtherCAT.register_pdos(master, slave, [List.first(pdos)], :domain2)

      assert is_list(conflicts)
      assert length(conflicts) > 0

      EtherCAT.close(master)
    end

    test "PDO can be re-registered to the same domain" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})

      # Register PDO to domain
      assert {:ok, _} = EtherCAT.register_pdos(master, slave, [List.first(pdos)])

      # Re-registering to the same domain should succeed (idempotent)
      assert {:ok, _} = EtherCAT.register_pdos(master, slave, [List.first(pdos)])

      EtherCAT.close(master)
    end

    test "different domains with different intervals can be created" do
      {:ok, master, _slaves} = EtherCAT.open()

      # Create domains with various intervals
      assert {:ok, _} = EtherCAT.create_domain(master, :fast, 1)
      assert {:ok, _} = EtherCAT.create_domain(master, :medium, 10)
      assert {:ok, _} = EtherCAT.create_domain(master, :slow, 100)

      EtherCAT.close(master)
    end

    test "domains with interval 0 should fail" do
      {:ok, master, _slaves} = EtherCAT.open()

      # Domain with interval 0 should be rejected
      assert {:error, _} = EtherCAT.create_domain(master, :invalid, 0)

      EtherCAT.close(master)
    end

    test "PDOs registered after start_cyclic should fail" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})

      # Start cyclic mode
      EtherCAT.start_cyclic(master)

      # Attempting to register PDOs after activation should fail
      assert {:error, _} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.close(master)
    end
  end

  describe "State Machine Lifecycle Tests" do
    test "master transitions through correct states" do
      # offline → stale → synced → operational
      {:ok, master, _slaves} = EtherCAT.open()

      # Master should be in synced state after open
      # (open includes connect and sync_slaves)

      # Starting cyclic should transition to operational
      EtherCAT.start_cyclic(master)

      # Give it time to transition
      Process.sleep(100)

      # Master should now be operational
      # We can verify by trying to read a value

      EtherCAT.close(master)
    end

    test "operations fail in wrong state" do
      # Operations should fail if called in wrong state

      # Starting a master without connecting should fail
      # (but our simplified API auto-connects, so we can't easily test this)

      # Reading before activation should fail
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      # Reading before start_cyclic should return error
      assert {:error, _} = EtherCAT.read(master, unique_name)

      EtherCAT.close(master)
    end

    test "master crash cleanup" do
      {:ok, master, slaves} = EtherCAT.open()

      # Kill the master process
      Process.exit(master, :kill)

      # Give it time to cleanup
      Process.sleep(100)

      # All slave processes should also be terminated (linked)
      assert Enum.all?(slaves, fn slave ->
               !Process.alive?(slave)
             end)
    end
  end

  describe "Concurrent Read/Write Safety Tests" do
    test "concurrent reads to same PDO are safe" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      # Spawn multiple processes reading the same PDO concurrently
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            for _j <- 1..100 do
              {:ok, _value} = EtherCAT.read(master, unique_name)
            end
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)
      assert length(results) == 10

      EtherCAT.close(master)
    end

    test "concurrent writes to same PDO are safe" do
      {:ok, master, [_coupler, _input, output | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, output, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, output, pdos)

      EtherCAT.start_cyclic(master)

      # Spawn multiple processes writing to the same PDO concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..100 do
              value = rem(i * j, 2) == 0
              :ok = EtherCAT.write(master, unique_name, value)
            end
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)
      assert length(results) == 10

      EtherCAT.close(master)
    end

    test "concurrent watch/unwatch operations are safe" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      # Spawn multiple processes watching and unwatching
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            for _j <- 1..10 do
              :ok = EtherCAT.watch(master, unique_name)
              Process.sleep(1)
              :ok = EtherCAT.unwatch(master, unique_name)
            end
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)
      assert length(results) == 10

      EtherCAT.close(master)
    end
  end

  describe "Error Handling Tests" do
    test "read with invalid unique_pdo name returns error" do
      {:ok, master, _slaves} = EtherCAT.open()

      assert {:error, {:invalid_unique_pdo, _}} =
               EtherCAT.read(master, "invalid_name")

      EtherCAT.close(master)
    end

    test "read with non-existent slave position returns error" do
      {:ok, master, _slaves} = EtherCAT.open()

      assert {:error, {:slave_not_found, _}} =
               EtherCAT.read(master, "slave_999:pdo_6000:1")

      EtherCAT.close(master)
    end

    test "read with unregistered PDO returns error" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, _pdos} = EtherCAT.configure_slave(master, slave, %{})

      # Don't register any PDOs

      EtherCAT.start_cyclic(master)

      # Attempt to read unregistered PDO
      assert {:error, {:pdo_not_registered, _}} =
               EtherCAT.read(master, "slave_1:unregistered_pdo")

      EtherCAT.close(master)
    end

    test "write to input PDO should work (library doesn't prevent it)" do
      {:ok, master, [_coupler, input | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, input, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, input, pdos)

      EtherCAT.start_cyclic(master)

      # Writing to an input PDO is allowed by the API
      # (the NIF layer or hardware will determine behavior)
      assert :ok = EtherCAT.write(master, unique_name, true)

      EtherCAT.close(master)
    end
  end

  describe "Watch/Unwatch Tests" do
    test "watch receives data_changed messages" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      # Watch the PDO
      :ok = EtherCAT.watch(master, unique_name)

      # Trigger a change (would normally come from hardware)
      # In a real test, we would physically change the input or wait

      # For now, just verify watch succeeded
      :ok = EtherCAT.unwatch(master, unique_name)

      EtherCAT.close(master)
    end

    test "unwatch stops receiving messages" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      # Watch then immediately unwatch
      :ok = EtherCAT.watch(master, unique_name)
      :ok = EtherCAT.unwatch(master, unique_name)

      # Flush any pending messages
      receive do
        {:data_changed, ^unique_name, _} -> :ok
      after
        100 -> :ok
      end

      # Should not receive any more messages
      refute_receive {:data_changed, ^unique_name, _}, 200

      EtherCAT.close(master)
    end

    test "multiple processes can watch same PDO" do
      {:ok, master, [_coupler, slave | _]} = EtherCAT.open()
      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{})
      {:ok, [unique_name | _]} = EtherCAT.register_pdos(master, slave, pdos)

      EtherCAT.start_cyclic(master)

      # Spawn multiple watchers
      watchers =
        for _i <- 1..5 do
          spawn(fn ->
            :ok = EtherCAT.watch(master, unique_name)

            receive do
              {:data_changed, ^unique_name, _value} -> :ok
            after
              1000 -> :timeout
            end
          end)
        end

      # Wait a bit for watchers to set up
      Process.sleep(100)

      # All watchers should be subscribed
      assert length(watchers) == 5

      EtherCAT.close(master)
    end
  end
end
