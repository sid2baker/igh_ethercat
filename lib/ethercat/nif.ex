defmodule EtherCAT.Nif do
  @moduledoc false

  use Zig,
    otp_app: :ethercat,
    leak_check: true,
    c: [
      include_dirs: "/usr/local/include/",
      link_lib: {:system, "ethercat"}
    ],
    nifs: [
      version_magic: [],
      request_master: [],
      master_activate: [],
      master_receive: [],
      master_send: [],
      master_application_time: [],
      master_sync_reference_clock: [],
      get_master_state: [],
      master_create_domain: [],
      master_slave_config: [],
      master_reset: [],
      release_master: [],
      master_get_slave: [],
      domain_process: [],
      domain_queue: [],
      get_domain_value_bool: [],
      set_domain_value_bool: [],
      domain_state: [],
      get_domain_size: [],
      slave_config_sync_manager: [],
      slave_config_pdo_assign_add: [],
      slave_config_pdo_assign_clear: [],
      slave_config_pdo_mapping_add: [],
      slave_config_pdo_mapping_clear: [],
      slave_config_reg_pdo_entry: [],
      slave_config_reg_pdo_entry_pos: [],
      master_get_sync_manager: [],
      master_get_pdo: [],
      master_get_pdo_entry: [],
      # maybe use dirty_cup/dirty_io
      listen_bus_changes: [:threaded],
      cyclic_task: [:threaded]
    ],
    resources: [
      :MasterResource,
      :DomainResource,
      :SlaveConfigResource
    ]

  ~Z"""
  const std = @import("std");
  const beam = @import("beam");
  const root = @import("root");
  const ecrt = @cImport(@cInclude("ecrt.h"));

  // ============================================================================
  // RESOURCE DEFINITIONS
  // ============================================================================

  /// EtherCAT master resource with automatic cleanup via dtor callback
  pub const MasterResource = beam.Resource(*ecrt.ec_master_t, root, .{ .Callbacks = MasterResourceCallbacks });

  /// EtherCAT domain resource
  pub const DomainResource = beam.Resource(*ecrt.ec_domain_t, root, .{});

  /// EtherCAT slave configuration resource
  pub const SlaveConfigResource = beam.Resource(*ecrt.ec_slave_config_t, root, .{});

  pub const MasterResourceCallbacks = struct {
      /// Destructor called when master resource is garbage collected
      pub fn dtor(s: **ecrt.ec_master_t) void {
          ecrt.ecrt_release_master(s.*);
      }
  };

  // ============================================================================
  // ERROR TYPES
  // ============================================================================

  const MasterError = error{
      MasterNotFound,
      ResetError,
      GetSlaveError,
      SlaveConfigError,
      ActivateError,
      PdoRegError,
      InvalidDomainData,
  };

  const DomainError = error{
      NullPointer,
      OutOfBounds,
      InvalidOffset,
      InvalidSize,
  };

  const MemoryError = error{
      OutOfMemory,
      AllocationFailed,
  };

  // ============================================================================
  // TYPE DEFINITIONS
  // ============================================================================

  /// Packed representation of ec_master_state_t
  /// Required because Zig doesn't support bitfields (see https://github.com/ziglang/zig/issues/1499)
  const packed_ec_master_state_t = packed struct {
      slaves_responding: u32,
      al_states: u4,
      link_up: u1,
      padding: u27, // Align to 64 bits (8 bytes)
  };

  /// Master state with expanded AL (Application Layer) state flags
  /// Each al_state_* flag is true if at least one slave is in that state
  const master_state_t = struct { slaves_responding: u32, al_state_init: u1, al_state_preop: u1, al_state_safeop: u1, al_state_op: u1, link_up: u1 };

  /// Packed representation of slave configuration state
  const ec_slave_config_state_t = packed struct {
      online: u1,
      operational: u1,
      al_state: u4,
      padding: u2, // Align to 8 bits (1 byte)
  };

  /// Configuration for a domain in cyclic task
  const domain_config_t = struct {
      pid: beam.pid,
      resource: DomainResource,
      interval: u32, // Multiplier for the base interval
  };

  /// Organized buffer structure for domain memory management
  /// All buffers are managed explicitly in Zig, with external buffer provided to EtherCAT library
  const DomainBuffers = struct {
      /// External buffer provided to EtherCAT library via ecrt_domain_external_memory()
      /// This is the "live" buffer that domain_process() reads/writes
      /// After domain_process(), this contains: inputs (updated from slaves) + outputs (echoed/stale)
      external: []u8,

      /// Preserves output values written by SET operations across cycles
      /// After domain_process() overwrites external buffer, we restore outputs from here
      /// Only dirty_bytes are copied: external[i] = output_state[i] where dirty_bytes[i] == true
      output_state: []u8,

      /// Bitmap marking which bytes are outputs (written by SET operations)
      /// true = output byte (must be preserved), false = input byte (read-only)
      /// This allows mixed input/output PDOs without explicit PDO layout knowledge
      dirty_bytes: []bool,

      /// Previous cycle's buffer state for efficient change detection
      /// We XOR external with previous to find changed bits in O(n) time
      previous: []u8,

      /// Cleanup all allocated buffers
      fn deinit(self: *DomainBuffers, allocator: std.mem.Allocator) void {
          allocator.free(self.external);
          allocator.free(self.output_state);
          allocator.free(self.dirty_bytes);
          allocator.free(self.previous);
      }
  };

  /// Output state buffer info for SET operations (used in global map)
  const OutputStateInfo = struct {
      buffer: []u8,
      dirty_bytes: []bool,
  };

  /// Global map of domain pointers to output state buffers
  /// Required because SET operations from Elixir processes must safely write outputs
  /// while cyclic task is running in a separate thread
  /// Thread-safe via mutex protection
  var output_state_map_mutex: std.Thread.Mutex = .{};
  var output_state_map: std.AutoHashMap(usize, OutputStateInfo) = undefined;
  var output_state_map_initialized: bool = false;

  /// Tracked domain state for cyclic task processing
  const DomainItem = struct {
      pid: beam.pid,
      domain: *ecrt.ec_domain_t,
      state: ecrt.ec_domain_state_t,
      buffers: DomainBuffers,
      interval: u32,

      /// Cleanup allocated memory for this domain item
      fn deinit(self: *DomainItem, allocator: std.mem.Allocator) void {
          self.buffers.deinit(allocator);
      }
  };

  // ============================================================================
  // MASTER OPERATIONS
  // ============================================================================

  /// Get the version magic number of the EtherCAT library
  pub fn version_magic() !u32 {
      return ecrt.ecrt_version_magic();
  }

  /// Request an EtherCAT master by index
  /// Returns {:ok, master_resource} on success
  pub fn request_master(index: u32) !beam.term {
      if (ecrt.ecrt_request_master(index)) |master| {
          const resource = try MasterResource.create(master, .{});
          return beam.make(.{ .ok, resource }, .{});
      } else {
          return beam.make_error_atom(.{});
      }
  }

  /// Activate the master
  /// Must be called after all configuration is complete and before cyclic operation
  pub fn master_activate(master: MasterResource) !void {
      const result = ecrt.ecrt_master_activate(master.unpack());
      if (result != 0) return MasterError.ActivateError;
  }

  /// Receive frames from the network
  /// Should be called at the beginning of each cyclic operation
  pub fn master_receive(master: MasterResource) !void {
      _ = ecrt.ecrt_master_receive(master.unpack());
  }

  /// Send frames to the network
  /// Should be called at the end of each cyclic operation
  pub fn master_send(master: MasterResource) !void {
      _ = ecrt.ecrt_master_send(master.unpack());
  }

  /// Set the application time for the master
  /// This must be called every cycle to synchronize with the EtherCAT master
  /// time_ns: application time in nanoseconds
  pub fn master_application_time(master: MasterResource, time_ns: u64) !void {
      _ = ecrt.ecrt_master_application_time(master.unpack(), time_ns);
  }

  /// Sync the reference clock
  /// Should be called after setting application time
  pub fn master_sync_reference_clock(master: MasterResource) !void {
      _ = ecrt.ecrt_master_sync_reference_clock(master.unpack());
  }

  /// Get the current state of the master
  /// Returns a master_state_t structure with slave and link information
  pub fn get_master_state(master: MasterResource) !beam.term {
      const master_state: master_state_t = try do_get_master_state(master.unpack());
      return beam.make(master_state, .{});
  }

  /// Internal helper to retrieve and unpack master state
  fn do_get_master_state(master: *ecrt.ec_master_t) !master_state_t {
      var packed_state: packed_ec_master_state_t = undefined;
      const result = ecrt.ecrt_master_state(master, @ptrCast(&packed_state));
      if (result != 0) {
          return MasterError.MasterNotFound;
      }
      return master_state_t{
          .slaves_responding = packed_state.slaves_responding,
          .al_state_init = @truncate(packed_state.al_states >> 0),
          .al_state_preop = @truncate(packed_state.al_states >> 1),
          .al_state_safeop = @truncate(packed_state.al_states >> 2),
          .al_state_op = @truncate(packed_state.al_states >> 3),
          .link_up = packed_state.link_up,
      };
  }

  /// Create a new domain
  /// Domains are used to group PDO registrations for efficient I/O
  pub fn master_create_domain(master: MasterResource) !DomainResource {
      const domain = ecrt.ecrt_master_create_domain(master.unpack()) orelse
          return MasterError.MasterNotFound;
      return DomainResource.create(domain, .{});
  }

  /// Configure a slave device
  /// Returns a slave configuration resource for further PDO configuration
  pub fn master_slave_config(master: MasterResource, alias: u16, position: u16, vendor_id: u32, product_code: u32) !SlaveConfigResource {
      const slave_config = ecrt.ecrt_master_slave_config(master.unpack(), alias, position, vendor_id, product_code) orelse return MasterError.SlaveConfigError;
      return SlaveConfigResource.create(slave_config, .{});
  }

  /// Get information about a slave at the given position
  pub fn master_get_slave(master: MasterResource, slave_position: u16) !beam.term {
      var slave_info: ecrt.ec_slave_info_t = undefined;
      const result = ecrt.ecrt_master_get_slave(master.unpack(), slave_position, &slave_info);
      if (result != 0) {
          return MasterError.GetSlaveError;
      }
      return beam.make(.{ .ok, slave_info }, .{});
  }

  /// Reset the master to initial state
  pub fn master_reset(master: MasterResource) !void {
      const result = ecrt.ecrt_master_reset(master.unpack());
      if (result != 0) {
          return MasterError.ResetError;
      }
  }

  /// Explicitly release the master
  /// Note: The dtor callback will also release the master on GC
  pub fn release_master(master: MasterResource) !void {
      ecrt.ecrt_release_master(master.unpack());
      master.release();
  }

  /// Get sync manager information for a slave
  pub fn master_get_sync_manager(master: MasterResource, slave_position: u16, sync_index: u8) !beam.term {
      var sync: ecrt.ec_sync_info_t = undefined;
      _ = ecrt.ecrt_master_get_sync_manager(master.unpack(), slave_position, sync_index, &sync);
      return beam.make(.{ .index = sync.index, .dir = sync.dir, .n_pdos = sync.n_pdos, .watchdog_mode = sync.watchdog_mode }, .{});
  }

  /// Get PDO information for a slave
  pub fn master_get_pdo(master: MasterResource, slave_position: u16, sync_index: u8, pos: u16) !beam.term {
      var pdo: ecrt.ec_pdo_info_t = undefined;
      _ = ecrt.ecrt_master_get_pdo(master.unpack(), slave_position, sync_index, pos, &pdo);
      return beam.make(.{ .index = pdo.index, .n_entries = pdo.n_entries }, .{});
  }

  /// Get PDO entry information for a slave
  pub fn master_get_pdo_entry(master: MasterResource, slave_position: u16, sync_index: u8, pdo_pos: u16, entry_pos: u16) !beam.term {
      var pdo_entry: ecrt.ec_pdo_entry_info_t = undefined;
      _ = ecrt.ecrt_master_get_pdo_entry(master.unpack(), slave_position, sync_index, pdo_pos, entry_pos, &pdo_entry);
      return beam.make(pdo_entry, .{});
  }

  // ============================================================================
  // DOMAIN OPERATIONS
  // ============================================================================

  /// Process domain data after receiving frames
  pub fn domain_process(domain: DomainResource) !void {
      _ = ecrt.ecrt_domain_process(domain.unpack());
  }

  /// Queue domain data for sending
  pub fn domain_queue(domain: DomainResource) !void {
      _ = ecrt.ecrt_domain_queue(domain.unpack());
  }

  /// Get a boolean value from domain data at the specified bit offset
  /// Note: ecrt_domain_data() returns the external buffer we provided via ecrt_domain_external_memory()
  pub fn get_domain_value_bool(domain: DomainResource, offset: usize) !bool {
      const data = ecrt.ecrt_domain_data(domain.unpack()) orelse
          return DomainError.NullPointer;
      const domain_size = ecrt.ecrt_domain_size(domain.unpack());

      if (offset >= domain_size * 8) return DomainError.OutOfBounds;

      const byte_index = offset / 8;
      const bit_index = @as(u3, @intCast(offset % 8));
      return (data[byte_index] >> bit_index) & 1 != 0;
  }

  /// Set a boolean value in domain data at the specified bit offset
  /// Thread-safe: Writes to output_state buffer to avoid race with cyclic task
  ///
  /// The cyclic task will restore this value from output_state to external buffer
  /// after domain_process() overwrites it. This ensures outputs are never lost.
  pub fn set_domain_value_bool(domain: DomainResource, offset: usize, value: bool) !void {
      const domain_ptr = domain.unpack();
      const domain_size = ecrt.ecrt_domain_size(domain_ptr);

      if (offset >= domain_size * 8) return DomainError.OutOfBounds;

      const byte_index = offset / 8;
      const bit_index = @as(u3, @intCast(offset % 8));

      // Look up output_state buffer for this domain (thread-safe via mutex)
      const domain_addr = @intFromPtr(domain_ptr);
      output_state_map_mutex.lock();
      defer output_state_map_mutex.unlock();

      if (output_state_map.get(domain_addr)) |info| {
          if (byte_index >= info.buffer.len) return DomainError.OutOfBounds;

          // Write to output_state buffer (cyclic task will copy to external buffer)
          if (value) {
              info.buffer[byte_index] |= (@as(u8, 1) << bit_index);
          } else {
              info.buffer[byte_index] &= ~(@as(u8, 1) << bit_index);
          }

          // Mark this byte as dirty (it's an output that must be preserved across cycles)
          info.dirty_bytes[byte_index] = true;
      } else {
          return DomainError.NullPointer; // Domain not registered in map
      }
  }

  /// Get the current state of the domain
  pub fn domain_state(domain: DomainResource) !beam.term {
      var state: ecrt.ec_domain_state_t = undefined;
      _ = ecrt.ecrt_domain_state(domain.unpack(), &state);
      return beam.make(state, .{});
  }

  /// Get the size of the domain data in bytes
  pub fn get_domain_size(domain: DomainResource) !usize {
      return ecrt.ecrt_domain_size(domain.unpack());
  }

  // ============================================================================
  // SLAVE CONFIGURATION OPERATIONS
  // ============================================================================

  /// Configure a sync manager for the slave
  pub fn slave_config_sync_manager(slave_config: SlaveConfigResource, sync_index: u8, direction: ecrt.ec_direction_t, watchdog_mode: ecrt.ec_watchdog_mode_t) !void {
      _ = ecrt.ecrt_slave_config_sync_manager(slave_config.unpack(), sync_index, direction, watchdog_mode);
  }

  /// Add a PDO to the sync manager's PDO assignment
  pub fn slave_config_pdo_assign_add(slave_config: SlaveConfigResource, sync_index: u8, index: u16) !void {
      _ = ecrt.ecrt_slave_config_pdo_assign_add(slave_config.unpack(), sync_index, index);
  }

  /// Clear the sync manager's PDO assignment
  pub fn slave_config_pdo_assign_clear(slave_config: SlaveConfigResource, sync_index: u8) !void {
      _ = ecrt.ecrt_slave_config_pdo_assign_clear(slave_config.unpack(), sync_index);
  }

  /// Add a PDO entry to a PDO's mapping
  pub fn slave_config_pdo_mapping_add(slave_config: SlaveConfigResource, pdo_index: u16, entry_index: u16, entry_subindex: u8, entry_bit_length: u8) !void {
      _ = ecrt.ecrt_slave_config_pdo_mapping_add(slave_config.unpack(), pdo_index, entry_index, entry_subindex, entry_bit_length);
  }

  /// Clear a PDO's mapping
  pub fn slave_config_pdo_mapping_clear(slave_config: SlaveConfigResource, pdo_index: u16) !void {
      _ = ecrt.ecrt_slave_config_pdo_mapping_clear(slave_config.unpack(), pdo_index);
  }

  /// Register a PDO entry for process data exchange
  /// Returns the offset in bits within the domain data
  pub fn slave_config_reg_pdo_entry(slave_config: SlaveConfigResource, entry_index: u16, entry_subindex: u8, domain: DomainResource) !usize {
      var bit_position: c_uint = 0;
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry(slave_config.unpack(), entry_index, entry_subindex, domain.unpack(), &bit_position);

      if (result >= 0) {
          return @as(usize, @intCast(result)) * 8 + bit_position;
      } else {
          return MasterError.PdoRegError;
      }
  }

  /// Register a PDO entry by position
  /// Returns the offset in bits within the domain data
  pub fn slave_config_reg_pdo_entry_pos(slave_config: SlaveConfigResource, sync_index: u8, pdo_pos: c_uint, entry_pos: c_uint, domain: DomainResource) !usize {
      var bit_position: c_uint = 0;
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry_pos(slave_config.unpack(), sync_index, pdo_pos, entry_pos, domain.unpack(), &bit_position);

      if (result >= 0) {
          return @as(usize, @intCast(result)) * 8 + bit_position;
      } else {
          return MasterError.PdoRegError;
      }
  }

  // ============================================================================
  // THREADED OPERATIONS
  // ============================================================================

  /// Listen for bus state changes and notify the Elixir process
  /// This runs in a separate thread and sends messages when the master state changes
  pub fn listen_bus_changes(pid: beam.pid, master_resource: MasterResource, interval: u64) !void {
      defer {
          beam.send(pid, .killed, .{}) catch {};
      }

      const master = master_resource.unpack();
      var state: master_state_t = try do_get_master_state(master);
      var last_state: master_state_t = undefined;

      while (true) {
          if (!std.meta.eql(last_state, state)) {
              _ = try beam.send(pid, .{ .master_state_changed, state }, .{});
          }
          last_state = state;
          state = try do_get_master_state(master);

          std.Thread.sleep(interval * std.time.ns_per_ms);
          try beam.yield();
      }
  }

  /// Main cyclic task for EtherCAT communication
  /// Handles master and domain processing, state monitoring, and data change detection
  /// Runs in a separate thread and sends notifications to registered processes
  ///
  /// Architecture:
  /// - Allocates external memory for each domain and provides to EtherCAT library
  /// - Uses DomainBuffers structure for organized memory management
  /// - Preserves outputs across cycles via dirty_bytes bitmap
  /// - Detects changes via XOR comparison with previous cycle
  pub fn cyclic_task(master_pid: beam.pid, master_resource: MasterResource, domain_configs: []domain_config_t, interval: u64) !void {
      const master = master_resource.unpack();
      var master_state: master_state_t = undefined;
      var prev_master_state: master_state_t = undefined;
      const yield_interval = @divTrunc(100_000, interval); // Yield every 100ms

      // Initialize domain tracking list
      var domains = std.ArrayList(DomainItem){};
      defer {
          // Clean up all allocated domain data
          for (domains.items) |*item| {
              item.deinit(beam.allocator);
          }
          domains.deinit(beam.allocator);
      }

      // Initialize global output_state map on first use
      if (!output_state_map_initialized) {
          output_state_map = std.AutoHashMap(usize, OutputStateInfo).init(beam.allocator);
          output_state_map_initialized = true;
      }

      // Set up domain tracking with external memory
      for (domain_configs) |domain_config| {
          const domain = domain_config.resource.unpack();
          const size = ecrt.ecrt_domain_size(domain);

          if (size == 0) return MasterError.InvalidDomainData;

          // Allocate external buffer for domain (this becomes the domain's working buffer)
          const external = beam.allocator.alloc(u8, size) catch
              return MemoryError.OutOfMemory;
          @memset(external, 0);

          // Provide external buffer to EtherCAT library
          // From now on, domain_process() will read/write to our external buffer
          ecrt.ecrt_domain_external_memory(domain, external.ptr);

          // Allocate output state buffer to preserve SET values across cycles
          const output_state = beam.allocator.alloc(u8, size) catch
              return MemoryError.OutOfMemory;
          @memset(output_state, 0);

          // Allocate dirty_bytes bitmap to track which bytes are outputs
          const dirty_bytes = beam.allocator.alloc(bool, size) catch
              return MemoryError.OutOfMemory;
          @memset(dirty_bytes, false);

          // Allocate previous buffer for change detection
          const previous = beam.allocator.alloc(u8, size) catch
              return MemoryError.OutOfMemory;
          @memcpy(previous, external);

          // Register this domain's output_state in the global map for SET operations
          const domain_addr = @intFromPtr(domain);
          output_state_map_mutex.lock();
          try output_state_map.put(domain_addr, .{ .buffer = output_state, .dirty_bytes = dirty_bytes });
          output_state_map_mutex.unlock();

          // Create DomainItem with organized buffers
          const buffers = DomainBuffers{
              .external = external,
              .output_state = output_state,
              .dirty_bytes = dirty_bytes,
              .previous = previous,
          };

          try domains.append(beam.allocator, .{
              .pid = domain_config.pid,
              .domain = domain,
              .state = undefined,
              .buffers = buffers,
              .interval = domain_config.interval,
          });
      }

      defer {
          beam.send(master_pid, .killed, .{}) catch {};
      }

      var counter: u32 = 0;
      var cycle_start_time: u64 = 0;

      // Initialize change tracking list (reused across cycles)
      var data_diffs = std.ArrayList(usize){};
      defer data_diffs.deinit(beam.allocator);

      // Main cyclic loop
      // Standard EtherCAT cycle order:
      // 1. Set application time
      // 2. Receive frames (get inputs from slaves)
      // 3. Process domains (library updates external buffer with inputs)
      // 4. Restore outputs (copy output_state → external for dirty bytes)
      // 5. Detect and notify changes
      // 6. Queue domains (prepare outputs to send)
      // 7. Send frames (transmit outputs to slaves)
      while (true) {
          // 1. Set application time (synchronize with master clock)
          cycle_start_time = cycle_start_time + (interval * std.time.ns_per_us);
          _ = ecrt.ecrt_master_application_time(master, cycle_start_time);

          // 2. Receive frames from network
          _ = ecrt.ecrt_master_receive(master);

          // 3-5. Process each domain
          for (domains.items) |*item| {
              var state: ecrt.ec_domain_state_t = undefined;

              // 3. Process domain data (library writes inputs to external buffer)
              // WARNING: This overwrites the ENTIRE external buffer, including outputs
              _ = ecrt.ecrt_domain_process(item.domain);

              // 4. Restore outputs from output_state buffer
              // Only restore dirty bytes (those explicitly set via SET operations)
              // This preserves outputs while allowing inputs to update naturally
              for (0..item.buffers.external.len) |i| {
                  if (item.buffers.dirty_bytes[i]) {
                      item.buffers.external[i] = item.buffers.output_state[i];
                  }
              }

              // Get domain state for monitoring
              _ = ecrt.ecrt_domain_state(item.domain, &state);

              // Notify working counter changes (for diagnostics)
              if (state.working_counter != item.state.working_counter) {
                  _ = try beam.send(item.pid, .{ .wc_changed, state.working_counter }, .{});
              }

              // Notify working counter state changes (for error detection)
              if (state.wc_state != item.state.wc_state) {
                  _ = try beam.send(item.pid, .{ .state_changed, state.wc_state }, .{});
              }

              // 5. Detect data changes at bit level using XOR
              data_diffs.clearRetainingCapacity();

              for (item.buffers.external, item.buffers.previous, 0..) |byte_a, byte_b, byte_i| {
                  const diff = byte_a ^ byte_b; // XOR to find differing bits

                  if (diff != 0) {
                      var bit_mask = diff;

                      while (bit_mask != 0) {
                          const bit_pos = @ctz(bit_mask); // Count trailing zeros
                          try data_diffs.append(beam.allocator, byte_i * 8 + bit_pos);
                          bit_mask &= bit_mask - 1; // Clear least significant set bit
                      }
                  }
              }

              // Notify subscribers of data changes
              if (data_diffs.items.len > 0) {
                  @memcpy(item.buffers.previous, item.buffers.external);
                  _ = try beam.send(item.pid, .{ .data_changed, item.buffers.external, data_diffs.items }, .{});
              }

              // Update state for next iteration
              item.state = state;
          }

          // Check and notify master state changes
          master_state = try do_get_master_state(master);

          if (!std.meta.eql(prev_master_state, master_state)) {
              _ = try beam.send(master_pid, .{ .master_state_changed, master_state }, .{});
          }

          prev_master_state = master_state;

          // 6. Queue domain outputs at configured intervals
          for (domains.items) |*item| {
              if (counter % item.interval == 0) {
                  _ = ecrt.ecrt_domain_queue(item.domain);
              }
          }

          // 7. Send queued frames to network
          _ = ecrt.ecrt_master_send(master);

          // Yield to BEAM scheduler periodically (every 100ms)
          if (counter % yield_interval == 0) {
              try beam.yield();
          }

          counter +%= 1; // Wrapping increment
          std.Thread.sleep(interval * std.time.ns_per_us);
      }
  }
  """
end
