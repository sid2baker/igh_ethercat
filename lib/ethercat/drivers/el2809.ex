defmodule EtherCAT.Drivers.EL2809 do
  @moduledoc """
  Beckhoff EL2809 16-channel digital output terminal driver.

  Provides 16 digital output channels with 24V DC, 0.5A per channel.
  All channels are mapped to a single 16-bit output word.
  """

  use EtherCAT.Slave.Driver
  require Logger

  @impl true
  def configure(_ctx, state, _config) do
    Logger.info("EL2809: 16-channel digital output terminal configured")
    {:ok, Map.put(state, :configured, true)}
  end

  @impl true
  def supports_pdo_config?(_state), do: false

  @impl true
  def list_pdos(_state) do
    [
      :ch1,
      :ch2,
      :ch3,
      :ch4,
      :ch5,
      :ch6,
      :ch7,
      :ch8,
      :ch9,
      :ch10,
      :ch11,
      :ch12,
      :ch13,
      :ch14,
      :ch15,
      :ch16
    ]
  end

  @impl true
  def pdo_info(_state, pdo_name) do
    case pdo_name do
      # SM0 - Channels 1-8
      :ch1 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1600,
           entries: %{output: {0x7000, 0x01, 1}}
         }}

      :ch2 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1601,
           entries: %{output: {0x7010, 0x01, 1}}
         }}

      :ch3 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1602,
           entries: %{output: {0x7020, 0x01, 1}}
         }}

      :ch4 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1603,
           entries: %{output: {0x7030, 0x01, 1}}
         }}

      :ch5 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1604,
           entries: %{output: {0x7040, 0x01, 1}}
         }}

      :ch6 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1605,
           entries: %{output: {0x7050, 0x01, 1}}
         }}

      :ch7 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1606,
           entries: %{output: {0x7060, 0x01, 1}}
         }}

      :ch8 ->
        {:ok,
         %{
           sync_manager: {0, :output, :default},
           pdo_index: 0x1607,
           entries: %{output: {0x7070, 0x01, 1}}
         }}

      # SM1 - Channels 9-16
      :ch9 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x1608,
           entries: %{output: {0x7080, 0x01, 1}}
         }}

      :ch10 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x1609,
           entries: %{output: {0x7090, 0x01, 1}}
         }}

      :ch11 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160A,
           entries: %{output: {0x70A0, 0x01, 1}}
         }}

      :ch12 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160B,
           entries: %{output: {0x70B0, 0x01, 1}}
         }}

      :ch13 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160C,
           entries: %{output: {0x70C0, 0x01, 1}}
         }}

      :ch14 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160D,
           entries: %{output: {0x70D0, 0x01, 1}}
         }}

      :ch15 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160E,
           entries: %{output: {0x70E0, 0x01, 1}}
         }}

      :ch16 ->
        {:ok,
         %{
           sync_manager: {1, :output, :default},
           pdo_index: 0x160F,
           entries: %{output: {0x70F0, 0x01, 1}}
         }}

      _ ->
        {:error, {:unknown_pdo, pdo_name}}
    end
  end

  @impl true
  def terminate(_state) do
    Logger.debug("Terminating EL2809 driver")
    :ok
  end

  # All entries use default boolean encoding/decoding (1 bit -> true/false)
  @impl true
  def decode_value(_state, _pdo_name, _entry_name, _data), do: :default

  @impl true
  def encode_value(_state, _pdo_name, _entry_name, _value), do: :default
end
