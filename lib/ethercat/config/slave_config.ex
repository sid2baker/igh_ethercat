defmodule EtherCAT.Config.SlaveConfig do
  @moduledoc """
  Slave device configuration.

  Defines how a slave at a specific bus position should be configured,
  including hardware identity verification, driver selection, driver-specific
  configuration (PDOs, SDOs), and entry-to-domain routing.

  ## Fields

  - `position` - Bus position (0-based)
  - `name` - Semantic slave name (e.g., `:digital_inputs`)
  - `device_identity` - Hardware verification (vendor_id, product_code, etc.)
  - `driver` - Driver module implementing EtherCAT.Slave.Driver behaviour
  - `config` - Driver-specific configuration map (e.g., `sync_managers`, `sdos`)
  - `registered_entries` - Entry-to-domain routing: `%{domain => [{pdo, entry}]}`

  ## Example

      %SlaveConfig{
        position: 1,
        name: :digital_inputs,
        device_identity: %{
          vendor_id: 0x00000002,
          product_code: 0x07113052,
          revision_no: 0x00120000,
          serial_no: nil
        },
        driver: nil,  # nil = GenericDriver
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
  """

  defstruct [
    :position,
    :name,
    :device_identity,
    :driver,
    :config,
    :registered_entries
  ]

  @type device_identity :: %{
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          revision_no: non_neg_integer() | nil,
          serial_no: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          position: non_neg_integer(),
          name: atom(),
          device_identity: device_identity(),
          driver: module() | nil,
          config: map(),
          registered_entries: %{atom() => [{atom(), atom()}]}
        }

  @doc """
  Creates a new slave configuration.

  ## Parameters
  - `position` - Bus position (0-based)
  - `opts` - Configuration options:
    - `:name` - Semantic slave name (required)
    - `:device_identity` - Hardware verification map (required)
    - `:driver` - Driver module (default: nil = GenericDriver)
    - `:config` - Driver-specific configuration (default: %{})
    - `:registered_entries` - Entry-to-domain routing (default: %{})
  """
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(position, opts \\ []) when is_integer(position) and position >= 0 do
    %__MODULE__{
      position: position,
      name: Keyword.fetch!(opts, :name),
      device_identity: Keyword.fetch!(opts, :device_identity),
      driver: Keyword.get(opts, :driver),
      config: Keyword.get(opts, :config, %{}),
      registered_entries: Keyword.get(opts, :registered_entries, %{})
    }
  end

  @doc """
  Validates slave configuration.

  Checks:
  - Position is non-negative integer
  - Name is an atom
  - Device identity format is valid
  - Driver is nil or a module
  - Config is a map
  - Registered entries format is valid
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = slave) do
    with :ok <- validate_position(slave.position),
         :ok <- validate_name(slave.name),
         :ok <- validate_device_identity(slave.device_identity),
         :ok <- validate_driver(slave.driver),
         :ok <- validate_config(slave.config),
         :ok <- validate_registered_entries(slave.registered_entries) do
      :ok
    end
  end

  defp validate_position(pos) when is_integer(pos) and pos >= 0, do: :ok
  defp validate_position(_), do: {:error, :invalid_position}

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_device_identity(%{vendor_id: v, product_code: p} = identity)
       when is_integer(v) and is_integer(p) do
    # revision_no and serial_no are optional
    with :ok <- validate_optional_integer(identity[:revision_no]),
         :ok <- validate_optional_integer(identity[:serial_no]) do
      :ok
    end
  end

  defp validate_device_identity(_), do: {:error, :invalid_device_identity}

  defp validate_optional_integer(nil), do: :ok
  defp validate_optional_integer(val) when is_integer(val), do: :ok
  defp validate_optional_integer(_), do: {:error, :invalid_optional_integer}

  defp validate_driver(nil), do: :ok
  defp validate_driver(driver) when is_atom(driver), do: :ok
  defp validate_driver(_), do: {:error, :invalid_driver}

  defp validate_config(config) when is_map(config), do: :ok
  defp validate_config(_), do: {:error, :config_must_be_map}

  defp validate_registered_entries(entries) when is_map(entries) do
    entries
    |> Enum.reduce_while(:ok, fn {domain, entry_list}, :ok ->
      if is_atom(domain) and valid_entry_list?(entry_list) do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_registered_entries_format}}
      end
    end)
  end

  defp validate_registered_entries(_), do: {:error, :registered_entries_must_be_map}

  defp valid_entry_list?(list) when is_list(list) do
    Enum.all?(list, fn
      {pdo, entry} when is_atom(pdo) and is_atom(entry) -> true
      _ -> false
    end)
  end

  defp valid_entry_list?(_), do: false
end
