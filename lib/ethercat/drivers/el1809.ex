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
    [:inputs]
  end

  @impl true
  def pdo_info(_state, pdo_name) do
    case pdo_name do
      :inputs ->
        {:ok,
         %{
           sync_manager: {3, :input, :default},
           pdo_index: 0x1A00,
           entries: %{
             ch1: {0x6000, 0x01, 1},
             ch2: {0x6000, 0x02, 1},
             ch3: {0x6000, 0x03, 1},
             ch4: {0x6000, 0x04, 1},
             ch5: {0x6000, 0x05, 1},
             ch6: {0x6000, 0x06, 1},
             ch7: {0x6000, 0x07, 1},
             ch8: {0x6000, 0x08, 1},
             ch9: {0x6000, 0x09, 1},
             ch10: {0x6000, 0x0A, 1},
             ch11: {0x6000, 0x0B, 1},
             ch12: {0x6000, 0x0C, 1},
             ch13: {0x6000, 0x0D, 1},
             ch14: {0x6000, 0x0E, 1},
             ch15: {0x6000, 0x0F, 1},
             ch16: {0x6000, 0x10, 1}
           }
         }}

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
