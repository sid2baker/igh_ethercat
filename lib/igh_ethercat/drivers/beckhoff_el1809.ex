defmodule IghEthercat.Drivers.DefaultDriver do
  @moduledoc """
  Example EtherCAT slave driver.

  This module demonstrates how to implement a simple EtherCAT slave driver.
  """

  use IghEthercat.Slave.Driver

  alias IghEthercat.{Nif, Slave, Domain}

  def configure(config) do
    {:ok, %{}}
  end

  def list_pdos(state) do
    [
      :input1,
      :input2,
      :input3,
      :input4,
      :input5,
      :input6,
      :input7,
      :input8,
      :input9,
      :input10,
      :input11,
      :input12,
      :input13,
      :input14,
      :input15,
      :input16
    ]
  end

  def pdo_info(state, pdo) do
    case pdo do
      :input1 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A00, entry: {0x6000, 0x01, 1}}}
      :input2 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A01, entry: {0x6010, 0x01, 1}}}
      :input3 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A02, entry: {0x6020, 0x01, 1}}}
      :input4 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A03, entry: {0x6030, 0x01, 1}}}
      :input5 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A04, entry: {0x6040, 0x01, 1}}}
      :input6 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A05, entry: {0x6050, 0x01, 1}}}
      :input7 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A06, entry: {0x6060, 0x01, 1}}}
      :input8 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A07, entry: {0x6070, 0x01, 1}}}
      :input9 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A08, entry: {0x6080, 0x01, 1}}}
      :input10 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A09, entry: {0x6090, 0x01, 1}}}
      :input11 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0A, entry: {0x60A0, 0x01, 1}}}
      :input12 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0B, entry: {0x60B0, 0x01, 1}}}
      :input13 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0C, entry: {0x60C0, 0x01, 1}}}
      :input14 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0D, entry: {0x60D0, 0x01, 1}}}
      :input15 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0E, entry: {0x60E0, 0x01, 1}}}
      :input16 -> {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A0F, entry: {0x60F0, 0x01, 1}}}
      _ -> {:error, :invalud_pdo}
    end
  end

  def terminate(state) do
    :ok
  end
end
