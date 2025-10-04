defmodule IghEthercat.Slave.Example do
  @moduledoc """
  Example EtherCAT slave driver.

  This module demonstrates how to implement a simple EtherCAT slave driver.
  """

  use IghEthercat.Slave.Driver

  alias IghEthercat.{Nif, Slave, Domain}

  @pdos [
    {0x1A00, {0x6000, 0x01, 1}},
    {0x1A01, {0x6010, 0x01, 1}},
    {0x1A02, {0x6020, 0x01, 1}},
    {0x1A03, {0x6030, 0x01, 1}},
    {0x1A04, {0x6040, 0x01, 1}},
    {0x1A05, {0x6050, 0x01, 1}},
    {0x1A06, {0x6060, 0x01, 1}},
    {0x1A07, {0x6070, 0x01, 1}}
  ]

  @impl true
  def configure(sc, config) do
    domain = Keyword.get(config, :domain)
    domain_ref = Domain.get_ref(domain)
    sync_index = 0
    direction = 2
    watchdog = 0

    Nif.slave_config_sync_manager(sc, sync_index, direction, watchdog)
    Nif.slave_config_pdo_assign_clear(sc, sync_index)

    inputs =
      for {pdo_index, {entry_index, entry_subindex, entry_size}} <- @pdos do
        Nif.slave_config_pdo_assign_add(sc, sync_index, pdo_index)
        Nif.slave_config_pdo_mapping_clear(sc, pdo_index)

        Nif.slave_config_pdo_mapping_add(sc, pdo_index, entry_index, entry_subindex, entry_size)

        offset = Nif.slave_config_reg_pdo_entry(sc, entry_index, entry_subindex, domain_ref)
        {domain, :bool, offset}
      end
      |> Enum.with_index()
      |> Enum.map(fn {input, index} ->
        {:"input#{index + 1}", input}
      end)
      |> Map.new()

    %{inputs: inputs, outputs: %{}}
  end

  @impl true
  def get_value(slave, variable) do
    GenServer.call(slave, {:get_value, variable})
  end

  @impl true
  def watch_value(slave, variable, pid) do
    # IghEthercat.Domain.subscribe(domain, self(), offset, entry_size)
    GenServer.call(slave, {:watch_value, variable, pid})
  end
end
