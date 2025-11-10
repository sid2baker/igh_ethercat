# Load test support modules
Code.require_file("support/hardware_helpers.ex", __DIR__)
Code.require_file("support/hardware_configs.ex", __DIR__)
Code.require_file("support/hardware_case.ex", __DIR__)

ExUnit.start(max_cases: 1)

# Exclude hardware tests by default - they require actual EtherCAT hardware
# Run with: mix test --include hardware
ExUnit.configure(exclude: [:hardware])
