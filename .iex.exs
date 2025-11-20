# IEx Configuration for EtherCAT Development
#
# This file is automatically loaded when starting IEx in dev/test environments.
# It provides convenient aliases and helpers for interactive development.

# Alias for shorter commands
alias EtherCAT.Master
alias EtherCAT.Config.{HardwareConfig, MasterConfig, DomainConfig, SlaveConfig}

# Load SimpleHardwareConfig from test/support
Code.require_file("test/support/simple_hardware_config.ex")
Code.require_file("examples/simple_io_test.ex")

# Create a shorter alias for the example module
alias Examples.SimpleIOTest, as: IOTest
