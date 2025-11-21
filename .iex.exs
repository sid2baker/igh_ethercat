# IEx Configuration for EtherCAT Development
#
# This file is automatically loaded when starting IEx in dev/test environments.
# It provides convenient aliases and helpers for interactive development.

# Alias for shorter commands
alias EtherCAT.Master
alias EtherCAT.Config.{HardwareConfig, MasterConfig, DomainConfig, SlaveConfig}

Code.require_file("test/support/drivers/el3202.ex")
Code.require_file("test/support/hardware_configs/hardware_config.ex")
Code.require_file("test/support/hardware_configs/simple_hardware_config.ex")
Code.require_file("examples/simple_io_test.ex")

# Create a shorter alias for the example module
alias Examples.SimpleIOTest, as: IOTest
