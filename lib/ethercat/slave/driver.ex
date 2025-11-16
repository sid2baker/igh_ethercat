defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave driver processes.

  Drivers implement encoding/decoding logic for PDO values. The behaviour
  provides all GenServer boilerplate, so implementing drivers just need to:

  1. Define encode_pdo_value/3 and decode_pdo_value/3 callbacks
  2. Optionally override default implementations for custom logic
  3. Implement init/1 to set up driver state

  ## Example Implementation

      defmodule MyDevice.Driver do
        use EtherCAT.Slave.Driver

        defstruct [:master, :position, :name, :config]

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        @impl true
        def init(opts) do
          state = %__MODULE__{
            master: Keyword.fetch!(opts, :master),
            position: Keyword.fetch!(opts, :position),
            name: Keyword.fetch!(opts, :name),
            config: Keyword.get(opts, :config, %{})
          }
          {:ok, state}
        end

        # Override encode/decode for custom behavior
        @impl true
        def encode_pdo_value(:temp, :value, celsius) do
          # Custom encoding: convert Celsius to raw ADC value
          raw = round(celsius * 10)
          <<raw::little-signed-16>>
        end

        def encode_pdo_value(pdo, entry, value) do
          # Fall back to default for other PDOs
          default_encode_pdo_value(pdo, entry, value)
        end

        @impl true
        def decode_pdo_value(:temp, :value, <<raw::little-signed-16>>) do
          # Custom decoding: convert raw ADC to Celsius
          raw / 10.0
        end

        def decode_pdo_value(pdo, entry, binary) do
          # Fall back to default for other PDOs
          default_decode_pdo_value(pdo, entry, binary)
        end
      end

  ## Usage

      {:ok, pid} = MyDevice.Driver.start_link(master: master_pid, position: 0, name: :temp_sensor)
      {:ok, temp} = MyDevice.Driver.read(pid, :temp, :value)  # => 25.6
      :ok = MyDevice.Driver.write(pid, :temp, :setpoint, 30.0)
  """

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  @doc """
  Encode a PDO value to binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to encode

  ## Returns
  Binary data ready to write to hardware
  """
  @callback encode_pdo_value(pdo_name(), entry_name(), value :: term()) :: binary()

  @doc """
  Decode a PDO value from binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `binary` - Raw binary data from hardware

  ## Returns
  Decoded value
  """
  @callback decode_pdo_value(pdo_name(), entry_name(), binary()) :: term()

  # ========================================================================
  # __using__ macro - Inject GenServer implementation
  # ========================================================================

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour EtherCAT.Slave.Driver

      # ======================================================================
      # Client API - Call the driver process
      # ======================================================================

      @doc """
      Read a PDO entry value.

      ## Parameters
      - `pid` - Driver process PID
      - `pdo_name` - PDO identifier (e.g., `:ch1`)
      - `entry_name` - Entry identifier (e.g., `:value`)

      ## Returns
      - `{:ok, decoded_value}` on success
      - `{:error, reason}` on failure
      """
      def read(pid, pdo_name, entry_name) when is_pid(pid) do
        GenServer.call(pid, {:read, pdo_name, entry_name})
      end

      @doc """
      Write a PDO entry value.

      ## Parameters
      - `pid` - Driver process PID
      - `pdo_name` - PDO identifier (e.g., `:ch1`)
      - `entry_name` - Entry identifier (e.g., `:value`)
      - `value` - Value to write (will be encoded by driver)

      ## Returns
      - `:ok` on success
      - `{:error, reason}` on failure
      """
      def write(pid, pdo_name, entry_name, value) when is_pid(pid) do
        GenServer.call(pid, {:write, pdo_name, entry_name, value})
      end

      @doc """
      Subscribe to value change notifications for a PDO entry.

      The subscriber will receive `{:pdo_value_changed, unique_name, value}`
      messages when the entry value changes.

      ## Parameters
      - `pid` - Driver process PID
      - `pdo_name` - PDO identifier (e.g., `:ch1`)
      - `entry_name` - Entry identifier (e.g., `:value`)
      - `subscriber` - PID to receive notifications

      ## Returns
      - `:ok` on success
      - `{:error, reason}` on failure
      """
      def subscribe(pid, pdo_name, entry_name, subscriber) when is_pid(pid) do
        GenServer.call(pid, {:subscribe, pdo_name, entry_name, subscriber})
      end

      @doc """
      Unsubscribe from value change notifications.

      ## Parameters
      - `pid` - Driver process PID
      - `pdo_name` - PDO identifier (e.g., `:ch1`)
      - `entry_name` - Entry identifier (e.g., `:value`)
      - `subscriber` - PID to unsubscribe

      ## Returns
      - `:ok` on success
      - `{:error, reason}` on failure
      """
      def unsubscribe(pid, pdo_name, entry_name, subscriber) when is_pid(pid) do
        GenServer.call(pid, {:unsubscribe, pdo_name, entry_name, subscriber})
      end

      # ======================================================================
      # GenServer Callbacks - Handle read/write/subscribe operations
      # ======================================================================

      @doc false
      def handle_call({:read, pdo_name, entry_name}, _from, state) do
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

        result =
          case EtherCAT.Master.read_pdo_entry(state.master, :default_domain, unique_name) do
            {:ok, binary_data} ->
              value = decode_pdo_value(pdo_name, entry_name, binary_data)
              {:ok, value}

            error ->
              error
          end

        {:reply, result, state}
      end

      def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
        binary_data = encode_pdo_value(pdo_name, entry_name, value)
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
        result = EtherCAT.Master.write_pdo_entry(state.master, :default_domain, unique_name, binary_data)
        {:reply, result, state}
      end

      def handle_call({:subscribe, pdo_name, entry_name, subscriber}, _from, state) do
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
        result = EtherCAT.Master.subscribe(state.master, :default_domain, unique_name, subscriber)
        {:reply, result, state}
      end

      def handle_call({:unsubscribe, pdo_name, entry_name, subscriber}, _from, state) do
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
        result = EtherCAT.Master.unsubscribe(state.master, :default_domain, unique_name, subscriber)
        {:reply, result, state}
      end

      # ======================================================================
      # Default Encode/Decode Implementations
      # ======================================================================

      @doc """
      Default PDO value encoding.

      Handles common types:
      - Booleans: `true` → `<<1>>`, `false` → `<<0>>`
      - Signed 16-bit integers: `value` → `<<value::little-signed-16>>`
      - Unsigned 16-bit integers: `value` → `<<value::little-unsigned-16>>`
      - Binary passthrough

      Override `encode_pdo_value/3` for custom encoding logic.
      """
      def default_encode_pdo_value(_pdo, _entry, value) when is_binary(value), do: value
      def default_encode_pdo_value(_pdo, _entry, true), do: <<1>>
      def default_encode_pdo_value(_pdo, _entry, false), do: <<0>>

      def default_encode_pdo_value(_pdo, _entry, value)
          when is_integer(value) and value >= -32768 and value <= 32767 do
        <<value::little-signed-16>>
      end

      def default_encode_pdo_value(_pdo, _entry, value)
          when is_integer(value) and value >= 0 and value <= 65535 do
        <<value::little-unsigned-16>>
      end

      @doc """
      Default PDO value decoding.

      Handles common types:
      - 16-bit signed integers
      - 16-bit unsigned integers
      - Booleans: `<<1>>` → `true`, `<<0>>` → `false`
      - Binary passthrough

      Override `decode_pdo_value/3` for custom decoding logic.
      """
      def default_decode_pdo_value(_pdo, _entry, <<value::little-signed-16>>), do: value
      def default_decode_pdo_value(_pdo, _entry, <<value::little-unsigned-16>>), do: value
      def default_decode_pdo_value(_pdo, _entry, <<1>>), do: true
      def default_decode_pdo_value(_pdo, _entry, <<0>>), do: false
      def default_decode_pdo_value(_pdo, _entry, binary), do: binary

      # ======================================================================
      # Default Callback Implementations
      # ======================================================================

      @doc """
      Default encode_pdo_value implementation.

      Delegates to default_encode_pdo_value/3. Override this function
      to provide custom encoding logic, and call default_encode_pdo_value/3
      for fallback behavior.
      """
      def encode_pdo_value(pdo, entry, value) do
        default_encode_pdo_value(pdo, entry, value)
      end

      @doc """
      Default decode_pdo_value implementation.

      Delegates to default_decode_pdo_value/3. Override this function
      to provide custom decoding logic, and call default_decode_pdo_value/3
      for fallback behavior.
      """
      def decode_pdo_value(pdo, entry, binary) do
        default_decode_pdo_value(pdo, entry, binary)
      end

      # Allow drivers to override these
      defoverridable encode_pdo_value: 3, decode_pdo_value: 3, handle_call: 3
    end
  end
end
