defmodule HardwareConfigs do
  @moduledoc """
  Pre-defined hardware configurations for testing.

  Makes it easy to declare and document expected hardware setups,
  improving test maintainability and making hardware requirements explicit.

  ## Usage

      # In your test file
      @hardware_config :basic_io_loopback

      test "my test", %{master: master, slaves: slaves} do
        config = HardwareConfigs.get(@hardware_config)
        # Use config.expected_slaves, config.loopback_pairs, etc.
      end
  """

  @type slave_type ::
          :coupler | :digital_input | :digital_output | :analog_input | :temperature_sensor

  @type hardware_config :: %{
          name: atom(),
          description: String.t(),
          expected_slaves: [slave_type()],
          min_slaves: non_neg_integer(),
          loopback_required: boolean(),
          loopback_pairs: [{non_neg_integer(), non_neg_integer()}],
          notes: String.t()
        }

  @doc """
  Returns configuration for basic I/O loopback testing.

  Expected setup:
  - Slave 0: EK1100 bus coupler
  - Slave 1: EL1809 digital input (16ch)
  - Slave 2: EL2809 digital output (16ch)
  - Physical wire: Output 1 → Input 1
  """
  @spec basic_io_loopback() :: hardware_config()
  def basic_io_loopback do
    %{
      name: :basic_io_loopback,
      description: "Basic digital I/O with loopback",
      expected_slaves: [:coupler, :digital_input, :digital_output],
      min_slaves: 3,
      loopback_required: true,
      loopback_pairs: [{1, 1}],
      notes: "Connect DO1 to DI1 with physical wire"
    }
  end

  @doc """
  Returns configuration for EL3202 temperature testing.

  Expected setup:
  - Slave 0: EK1100 bus coupler
  - Slave 1: EL1008 digital input (optional)
  - Slave 2: EL2008 digital output (optional)
  - Slave 3: EL3202 RTD temperature input (2ch)
  """
  @spec el3202_temperature() :: hardware_config()
  def el3202_temperature do
    %{
      name: :el3202_temperature,
      description: "EL3202 RTD temperature sensor testing",
      expected_slaves: [:coupler, :digital_input, :digital_output, :temperature_sensor],
      min_slaves: 4,
      loopback_required: false,
      loopback_pairs: [],
      notes: "Connect PT100/PT1000 sensors to EL3202 channels"
    }
  end

  @doc """
  Returns configuration for multi-domain testing.

  Expected setup:
  - Slave 0: EK1100 bus coupler
  - Slave 1+: Any I/O terminal with multiple PDOs
  """
  @spec multi_domain() :: hardware_config()
  def multi_domain do
    %{
      name: :multi_domain,
      description: "Multi-rate domain testing",
      expected_slaves: [:coupler, :digital_input],
      min_slaves: 2,
      loopback_required: false,
      loopback_pairs: [],
      notes: "Any I/O terminal sufficient for PDO distribution across domains"
    }
  end

  @doc """
  Returns configuration for minimal testing.

  Expected setup:
  - Slave 0: Any slave (even standalone terminal without coupler)
  """
  @spec minimal() :: hardware_config()
  def minimal do
    %{
      name: :minimal,
      description: "Minimal single-slave setup",
      expected_slaves: [:digital_input],
      min_slaves: 1,
      loopback_required: false,
      loopback_pairs: [],
      notes: "Any single EtherCAT slave for basic connectivity testing"
    }
  end

  @doc """
  Gets configuration by name.
  """
  @spec get(atom()) :: hardware_config()
  def get(name) do
    case name do
      :basic_io_loopback -> basic_io_loopback()
      :el3202_temperature -> el3202_temperature()
      :multi_domain -> multi_domain()
      :minimal -> minimal()
      _ -> raise "Unknown hardware configuration: #{inspect(name)}"
    end
  end

  @doc """
  Validates that the actual slaves match expected configuration.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(hardware_config(), [pid()]) :: :ok | {:error, String.t()}
  def validate(config, slaves) do
    actual_count = length(slaves)

    cond do
      actual_count < config.min_slaves ->
        {:error,
         "Expected at least #{config.min_slaves} slaves, found #{actual_count}. " <>
           "Required setup: #{config.description}"}

      true ->
        :ok
    end
  end
end
