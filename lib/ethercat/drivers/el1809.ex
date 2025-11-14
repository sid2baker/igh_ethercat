defmodule EtherCAT.Drivers.EL1809 do
  @moduledoc """
  Beckhoff EL1809 16-channel digital input terminal driver.

  Provides 16 digital input channels with 24V DC input voltage.
  All channels are mapped to a single 16-bit input word.
  """

  use EtherCAT.Slave.Driver
  require Logger

  @impl true
  def configure(_ctx, state, _config) do
    Logger.info("EL1809: 16-channel digital input terminal configured")
    {:ok, Map.put(state, :configured, true)}
  end

  @impl true
  def supports_pdo_config?(_state), do: false

  @impl true
  def list_pdos(_state) do
    [:ch1, :ch2, :ch3, :ch4, :ch5, :ch6, :ch7, :ch8,
     :ch9, :ch10, :ch11, :ch12, :ch13, :ch14, :ch15, :ch16]
  end

  @impl true
  def pdo_info(_state, pdo_name) do
    case pdo_name do
      :ch1 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A00,
                entries: %{input: {0x6000, 0x01, 1}}}}
      :ch2 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A01,
                entries: %{input: {0x6010, 0x01, 1}}}}
      :ch3 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A02,
                entries: %{input: {0x6020, 0x01, 1}}}}
      :ch4 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A03,
                entries: %{input: {0x6030, 0x01, 1}}}}
      :ch5 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A04,
                entries: %{input: {0x6040, 0x01, 1}}}}
      :ch6 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A05,
                entries: %{input: {0x6050, 0x01, 1}}}}
      :ch7 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A06,
                entries: %{input: {0x6060, 0x01, 1}}}}
      :ch8 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A07,
                entries: %{input: {0x6070, 0x01, 1}}}}
      :ch9 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A08,
                entries: %{input: {0x6080, 0x01, 1}}}}
      :ch10 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A09,
                entries: %{input: {0x6090, 0x01, 1}}}}
      :ch11 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0A,
                entries: %{input: {0x60A0, 0x01, 1}}}}
      :ch12 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0B,
                entries: %{input: {0x60B0, 0x01, 1}}}}
      :ch13 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0C,
                entries: %{input: {0x60C0, 0x01, 1}}}}
      :ch14 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0D,
                entries: %{input: {0x60D0, 0x01, 1}}}}
      :ch15 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0E,
                entries: %{input: {0x60E0, 0x01, 1}}}}
      :ch16 ->
        {:ok, %{sync_manager: {0, :input, :default}, pdo_index: 0x1A0F,
                entries: %{input: {0x60F0, 0x01, 1}}}}

      _ ->
        {:error, {:unknown_pdo, pdo_name}}
    end
  end

  @impl true
  def terminate(_state) do
    Logger.debug("Terminating EL1809 driver")
    :ok
  end

  # All entries use default boolean encoding/decoding (1 bit -> true/false)
  @impl true
  def decode_value(_state, _pdo_name, _entry_name, _data), do: :default

  @impl true
  def encode_value(_state, _pdo_name, _entry_name, _value), do: :default
end
