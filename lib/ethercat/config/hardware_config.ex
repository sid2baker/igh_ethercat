defmodule EtherCAT.Config.HardwareConfig do
  @moduledoc """
  Complete EtherCAT system hardware configuration.

  This struct represents the full declarative configuration of an EtherCAT system,
  including master settings, domains, slaves, and entry routing.
  """

  alias EtherCAT.Config.{MasterConfig, DomainConfig, SlaveConfig}

  defstruct [
    :master,
    :domains,
    :slaves
  ]

  @type t :: %__MODULE__{
          master: MasterConfig.t() | nil,
          domains: [DomainConfig.t()],
          slaves: [SlaveConfig.t()]
        }

  @doc """
  Creates a new hardware configuration.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      master: Keyword.get(opts, :master),
      domains: Keyword.get(opts, :domains, []),
      slaves: Keyword.get(opts, :slaves, [])
    }
  end

  @doc """
  Validates the hardware configuration for consistency.

  Checks:
  - Master configuration is valid (if specified)
  - All referenced domains exist
  - No duplicate slave positions
  - No duplicate slave names
  - All entry domain references are valid
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = config) do
    with :ok <- validate_master(config),
         :ok <- validate_domains(config),
         :ok <- validate_slaves(config),
         :ok <- validate_entry_domains(config) do
      :ok
    end
  end

  defp validate_master(%{master: nil}), do: :ok
  defp validate_master(%{master: master}), do: MasterConfig.validate(master)

  defp validate_domains(%{domains: domains}) do
    names = Enum.map(domains, & &1.name)
    duplicates = names -- Enum.uniq(names)

    if Enum.empty?(duplicates) do
      :ok
    else
      {:error, {:duplicate_domains, duplicates}}
    end
  end

  defp validate_slaves(%{slaves: slaves}) do
    positions = Enum.map(slaves, & &1.position)
    position_duplicates = positions -- Enum.uniq(positions)

    names = Enum.map(slaves, & &1.name) |> Enum.reject(&is_nil/1)
    name_duplicates = names -- Enum.uniq(names)

    cond do
      not Enum.empty?(position_duplicates) ->
        {:error, {:duplicate_positions, position_duplicates}}

      not Enum.empty?(name_duplicates) ->
        {:error, {:duplicate_slave_names, name_duplicates}}

      true ->
        :ok
    end
  end

  defp validate_entry_domains(%{domains: domains, slaves: slaves}) do
    domain_names = MapSet.new(domains, & &1.name)

    invalid_refs =
      Enum.flat_map(slaves, fn slave ->
        Enum.filter(slave.entries, fn entry ->
          not MapSet.member?(domain_names, entry.domain)
        end)
      end)

    if Enum.empty?(invalid_refs) do
      :ok
    else
      invalid_domains = Enum.map(invalid_refs, & &1.domain) |> Enum.uniq()
      {:error, {:unknown_domains, invalid_domains}}
    end
  end
end
