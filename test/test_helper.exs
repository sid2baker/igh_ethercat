ExUnit.start(max_cases: 1)

# Exclude hardware tests by default - they require actual EtherCAT hardware
# Run with: mix test --include hardware
ExUnit.configure(exclude: [:hardware])
