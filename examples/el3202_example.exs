# Example usage of the EL3202 RTD temperature input driver
#
# This example shows how to configure and use an EL3202 2-channel RTD
# temperature input terminal with limit monitoring and filtering.

defmodule EL3202Example do
  @moduledoc """
  Example application using the EL3202 RTD temperature input driver.

  Hardware setup:
  - Position 1: EK1100 Coupler
  - Position 2: EL1008 8-channel digital input (or similar)
  - Position 3: EL2008 8-channel digital output (or similar)
  - Position 4: EL3202 2-channel RTD temperature input
  """

  alias EtherCAT.{Master, Slave}

  def run do
    # Start the EtherCAT master
    {:ok, master} = Master.start_link(master_index: 0)

    # Connect to the bus
    :ok = Master.connect(master)

    # Sync slaves (discover topology)
    :ok = Master.sync_slaves(master)

    # Configure EL3202 at position 4 with temperature limits
    config = %{
      # Channel 1: Monitor room temperature (20-25°C)
      # 20.0°C (in 0.1°C units)
      ch1_limit1: 200,
      # 25.0°C
      ch1_limit2: 250,
      ch1_enable_limit1: true,
      ch1_enable_limit2: true,
      ch1_enable_filter: true,
      ch1_filter_settings: 10,

      # Channel 2: Monitor process temperature (0-50°C)
      # 0.0°C
      ch2_limit1: 0,
      # 50.0°C
      ch2_limit2: 500,
      ch2_enable_limit1: true,
      ch2_enable_limit2: true,
      ch2_enable_filter: true,
      ch2_filter_settings: 10
    }

    # Start slave process with EL3202 driver
    {:ok, slave_pid} =
      Slave.start_link(
        master: master,
        position: 4,
        driver: EtherCAT.Drivers.EL3202,
        driver_config: config
      )

    # Configure slave (applies SDO settings)
    :ok = Slave.configure(slave_pid)

    # Register PDOs for cyclic data exchange
    pdos_to_register = [
      # Temperature value channel 1
      :ch1_value,
      # Error flag channel 1
      :ch1_error,
      # Underrange flag
      :ch1_underrange,
      # Overrange flag
      :ch1_overrange,
      # Limit 1 status
      :ch1_limit1,
      # Limit 2 status
      :ch1_limit2,
      # Temperature value channel 2
      :ch2_value,
      # Error flag channel 2
      :ch2_error,
      :ch2_underrange,
      :ch2_overrange,
      :ch2_limit1,
      :ch2_limit2
    ]

    :ok = Slave.register_pdos(slave_pid, pdos_to_register)

    # Create domain for cyclic communication
    # 1ms cycle
    {:ok, domain} = Master.create_domain(master, "main", 1000)

    # Start cyclic mode
    :ok = Master.start_cyclic_mode(master)

    # Subscribe to temperature value changes
    :ok = Master.domain_subscribe(master, domain, self(), "ch1_value")
    :ok = Master.domain_subscribe(master, domain, self(), "ch2_value")

    # Monitor temperature readings
    monitor_temperatures()
  end

  defp monitor_temperatures do
    receive do
      {:data_changed, "ch1_value", value} ->
        temp_c = value / 10.0
        IO.puts("Channel 1 Temperature: #{temp_c}°C")
        monitor_temperatures()

      {:data_changed, "ch2_value", value} ->
        temp_c = value / 10.0
        IO.puts("Channel 2 Temperature: #{temp_c}°C")
        monitor_temperatures()

      msg ->
        IO.inspect(msg, label: "Received")
        monitor_temperatures()
    end
  end
end

# Run the example (requires actual EL3202 hardware)
# EL3202Example.run()
