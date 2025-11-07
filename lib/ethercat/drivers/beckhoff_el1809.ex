defmodule EtherCAT.Drivers.BeckhoffEL1809 do
  @moduledoc """
  Driver for Beckhoff EL1809 16-channel digital input terminal.

  The EL1809 is a digital input terminal with 16 channels for 24V DC signals.
  Each channel provides a single bit input with a 3ms input filter.

  ## Specifications

  - Vendor ID: 0x00000002 (Beckhoff)
  - Product Code: 0x07113052
  - 16 digital inputs (24V DC)
  - Single-ended, 3ms input filter
  - LED status indicators per channel

  ## PDO Mappings

  Each input channel is mapped to a dedicated PDO:
  - `:input1` through `:input16` - Individual channel inputs (1 bit each)
  - All inputs use sync manager 0 (SM0) with direction 2 (input/read)
  - PDO indices: 0x1A00 through 0x1A0F
  - Object dictionary base: 0x6000 through 0x60F0

  ## Example Usage

      # Configure a Beckhoff EL1809 slave
      alias EtherCAT.Drivers.BeckhoffEL1809
      {:ok, slave} = Slave.create(master, position, BeckhoffEL1809, config, sync_count)

      # List available inputs
      Slave.list_pdos(slave)
      #=> [:input1, :input2, ..., :input16]

      # Register specific inputs
      Slave.register_pdos(slave, [:input1, :input2, :input3], :default_domain)
  """
  use EtherCAT.Slave.Driver

  # Device specifications
  @vendor_id 0x00000002
  @product_code 0x07113052
  @channel_count 16

  # Sync manager configuration (shared by all channels)
  @sync_manager {0, 2, 0}

  # Generate PDO mappings at compile time
  @pdo_mappings for channel <- 1..@channel_count do
                  pdo_name = :"input#{channel}"
                  pdo_index = 0x1A00 + (channel - 1)
                  entry_index = 0x6000 + (channel - 1) * 0x10

                  {pdo_name,
                   %{
                     sync_manager: @sync_manager,
                     pdo_index: pdo_index,
                     entry: {entry_index, 0x01, 1}
                   }}
                end
                |> Map.new()

  @impl true
  def configure(state, _config) when is_map(state) do
    {:ok, state}
  end

  @impl true
  def list_pdos(_state) do
    Enum.map(1..@channel_count, &:"input#{&1}")
  end

  @impl true
  def pdo_info(_state, pdo_name) when is_atom(pdo_name) do
    case Map.fetch(@pdo_mappings, pdo_name) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:unknown_pdo, pdo_name}}
    end
  end

  @impl true
  def terminate(_state), do: :ok

  @doc """
  Returns the vendor ID for Beckhoff devices.
  """
  def vendor_id, do: @vendor_id

  @doc """
  Returns the product code for the EL1809 terminal.
  """
  def product_code, do: @product_code

  @doc """
  Returns the number of input channels.
  """
  def channel_count, do: @channel_count
end
