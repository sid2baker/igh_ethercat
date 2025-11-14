# Start ExUnit
ExUnit.start()

# Configure test output
ExUnit.configure(exclude: [:hardware], formatters: [ExUnit.CLIFormatter])

# Display hardware test instructions
unless System.get_env("ETHERCAT_HARDWARE") == "true" do
  IO.puts("\n")
  IO.puts("========================================")
  IO.puts("Hardware tests are excluded by default.")
  IO.puts("To run hardware tests:")
  IO.puts("  ETHERCAT_HARDWARE=true mix test --only hardware")
  IO.puts("")
  IO.puts("To run specific hardware test suites:")
  IO.puts("  ETHERCAT_HARDWARE=true mix test --only hardware:digital_io")
  IO.puts("  ETHERCAT_HARDWARE=true mix test --only hardware:rtd")
  IO.puts("========================================")
  IO.puts("\n")
end
