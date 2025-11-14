defmodule Examples.ExampleConfig do
  @moduledoc """
  Example EtherCAT configuration demonstrating the Spark formatter.

  Before formatting, this file has slaves defined before domains (wrong order).
  After running `mix format`, the formatter will reorder sections so domains come first.

  Run: mix format examples/example_config.ex
  """

  use EtherCAT.Config

  # This slave is intentionally placed BEFORE the domain definitions
  # The formatter will move it after the domains
  slave position: 1, name: :digital_outputs do
    driver EtherCAT.Drivers.EL2809
    expect vendor: 0x00000002, product: 0x0AF93052

    entry :ch1, :output, domain: :io_domain
    entry :ch2, :output, domain: :io_domain
  end

  # Domains should be defined first (before slaves that reference them)
  # The formatter will move these to the top
  domain :io_domain, interval: 1
  domain :slow_loop, interval: 10

  # Another slave that will stay in relative position
  slave position: 0, name: :temp_sensor do
    driver EtherCAT.Drivers.EL3202

    expect vendor: 0x00000002, product: 0x0C5A3052

    config do
      ch1_rtd_element 0
      ch2_rtd_element 0
      ch1_connection 1
      ch2_connection 1
    end

    entry :ch1, :value, domain: :io_domain
    entry :ch1, :error, domain: :slow_loop
    entry :ch2, :value, domain: :io_domain
    entry :ch2, :error, domain: :slow_loop
  end
end
