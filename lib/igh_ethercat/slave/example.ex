defmodule IghEthercat.Slave.Example do
  @moduledoc """
  Example EtherCAT slave driver.

  This module demonstrates how to implement a simple EtherCAT slave driver.
  """

  use IghEthercat.Slave.Driver

  alias IghEthercat.Nif

  @pdos [
    {0x1A00, {0x6000, 0x01, 1}},
    {0x1A01, {0x6010, 0x01, 1}},
    {0x1A02, {0x6020, 0x01, 1}},
    {0x1A03, {0x6030, 0x01, 1}}
  ]

  @impl true
  def register_all(master, domain, sc) do
  end

  @impl true
  def subscribe_all(master, domain, sc) do
    sync_index = 0
    direction = 2
    watchdog = 0

    Nif.slave_config_sync_manager(sc, sync_index, direction, watchdog)
    Nif.slave_config_pdo_assign_clear(sc, sync_index)

    for {pdo_index, {entry_index, entry_subindex, entry_size}} <- @pdos do
      Nif.slave_config_pdo_assign_add(sc, sync_index, pdo_index)
      Nif.slave_config_pdo_mapping_clear(sc, pdo_index)

      Nif.slave_config_pdo_mapping_add(sc, pdo_index, entry_index, entry_subindex, entry_size)

      Nif.slave_config_reg_pdo_entry(sc, entry_index, entry_subindex, domain)
    end
  end
end
