defmodule EtherCAT.Slave.GenericDriver do
  @moduledoc """
  Generic EtherCAT slave driver with type-based encoding/decoding.

  This is the default driver used when `driver: nil` in SlaveConfig.
  It provides:
  - Type-based encoding/decoding inferred from bit lengths
  - SDO configuration pass-through
  - PDO configuration pass-through
  - Standard read/write/subscribe operations

  ## Usage

  The GenericDriver is used automatically when no driver is specified:

      %SlaveConfig{
        position: 1,
        name: :my_device,
        driver: nil,  # GenericDriver used automatically
        device_identity: %{vendor_id: 0x00000002, product_code: 0x12345678},
        config: %{
          sdos: [
            %SdoConfig{index: 0x8000, subindex: 0x01, data: <<0xFF>>}
          ],
          sync_managers: [
            %SyncManagerConfig{
              index: 3,
              direction: :input,
              watchdog: :disable,
              pdos: [
                %PdoConfig{
                  index: 0x1A00,
                  name: :channel_1,
                  entries: %{input: {0x6000, 0x01, 1}}
                }
              ]
            }
          ]
        },
        registered_entries: %{
          default_domain: [{:channel_1, :input}]
        }
      }

  For custom encoding logic or complex state machines, implement a full driver
  using `use EtherCAT.Slave.Driver`.
  """

  use EtherCAT.Slave.Driver
  require Logger

  alias EtherCAT.Slave.Driver

  defstruct [:master, :position, :name, :sync_managers, :sdos]

  @type t :: %__MODULE__{
          master: pid(),
          position: non_neg_integer(),
          name: atom(),
          sync_managers: [EtherCAT.Config.SyncManagerConfig.t()],
          sdos: [EtherCAT.Config.SdoConfig.t()]
        }

  # ========================================================================
  # GenServer Callbacks
  # ========================================================================

  @impl GenServer
  def init(opts) do
    position = Keyword.fetch!(opts, :position)
    name = Keyword.fetch!(opts, :name)
    config = Keyword.fetch!(opts, :config)

    state = %__MODULE__{
      master: Keyword.fetch!(opts, :master),
      position: position,
      name: name,
      sync_managers: config[:sync_managers] || [],
      sdos: config[:sdos] || []
    }

    Logger.info("GenericDriver started for slave #{position} (#{name})")

    {:ok, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("GenericDriver terminating for slave #{state.position}: #{inspect(reason)}")
    :ok
  end

  # ========================================================================
  # Driver Behaviour Callbacks
  # ========================================================================

  @impl EtherCAT.Slave.Driver
  def configurable_pdos?(_state), do: true

  @impl EtherCAT.Slave.Driver
  def get_sdo_config(state), do: state.sdos

  @impl EtherCAT.Slave.Driver
  def get_pdo_config(state), do: state.sync_managers

  @impl EtherCAT.Slave.Driver
  def encode_pdo_value(pdo_name, entry_name, value, state) do
    type = find_type(state.sync_managers, pdo_name, entry_name)
    Driver.encode_by_type(type, value)
  end

  @impl EtherCAT.Slave.Driver
  def decode_pdo_value(pdo_name, entry_name, binary, state) do
    type = find_type(state.sync_managers, pdo_name, entry_name)
    Driver.decode_by_type(type, binary)
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # Find entry type from sync_managers structure
  defp find_type(sync_managers, pdo_name, entry_name) do
    Enum.find_value(sync_managers, fn sm ->
      pdo = Enum.find(sm.pdos, &(&1.name == pdo_name))

      if pdo && Map.has_key?(pdo.entries, entry_name) do
        {_index, _subindex, bit_length} = pdo.entries[entry_name]
        Driver.infer_type_from_bit_length(bit_length)
      end
    end) || :uint16
  end
end
