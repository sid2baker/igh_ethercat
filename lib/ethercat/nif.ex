defmodule EtherCAT.Nif do
  @moduledoc false

  @nerves_sysroot System.get_env("NERVES_SDK_SYSROOT")

  @default_include_dir if @nerves_sysroot,
                         do: Path.join(@nerves_sysroot, "usr/include"),
                         else: "/usr/local/include"

  @default_lib_dir if @nerves_sysroot,
                     do: Path.join(@nerves_sysroot, "usr/lib"),
                     else: "/usr/local/lib64"

  @igh_include_dir Application.compile_env(:ethercat, :igh_include_dir, @default_include_dir)
  @igh_lib_dir Application.compile_env(:ethercat, :igh_lib_dir, @default_lib_dir)

  use Zig,
    otp_app: :ethercat,
    c: [
      include_dirs: [@igh_include_dir],
      library_dirs: [@igh_lib_dir],
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
      get_value: [],
      set_value: [],
      domain_state: [],
      get_domain_size: [],
      slave_config_sync_manager: [],
      slave_config_pdo_assign_add: [],
      slave_config_pdo_assign_clear: [],
      slave_config_pdo_mapping_add: [],
      slave_config_pdo_mapping_clear: [],
      slave_config_reg_pdo_entry: [],
      slave_config_sdo: [],
      master_get_sync_manager: [],
      master_get_pdo: [],
      master_get_pdo_entry: [],
      # maybe use dirty_cup/dirty_io
      cyclic_task: [:threaded]
    ],
    resources: [
      :MasterResource,
      :DomainAccessorResource,
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

  /// EtherCAT domain accessor resource with layout descriptors
  pub const DomainAccessorResource = beam.Resource(*DomainAccessor, root, .{ .Callbacks = DomainAccessorCallbacks });

  /// EtherCAT slave configuration resource
  pub const SlaveConfigResource = beam.Resource(*ecrt.ec_slave_config_t, root, .{});

  pub const MasterResourceCallbacks = struct {
      /// Destructor called when master resource is garbage collected
      pub fn dtor(s: **ecrt.ec_master_t) void {
          ecrt.ecrt_release_master(s.*);
      }
  };

  pub const DomainAccessorCallbacks = struct {
      /// Destructor called when domain accessor resource is garbage collected
      pub fn dtor(accessor: **DomainAccessor) void {
          accessor.*.deinit();
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
      DuplicateEntry,
      OverlappingEntries,
      TooManyEntries,
  };

  const MemoryError = error{
      OutOfMemory,
      AllocationFailed,
  };

  // ============================================================================
  // CONSTANTS
  // ============================================================================

  /// Maximum size for PDO entry value storage in bytes
  const MAX_PDO_ENTRY_BYTES = 8;

  /// Maximum number of PDO entries per domain to prevent unbounded growth
  const MAX_ENTRIES_PER_DOMAIN = 1024;

  // ============================================================================
  // TYPE DEFINITIONS
  // ============================================================================

  /// PDO direction (maps to ec_direction_t)
  pub const PdoDirection = enum {
      invalid,
      output,
      input,
      count,
  };

  /// Sync manager watchdog mode (maps to ec_watchdog_mode_t)
  pub const WatchdogMode = enum {
      default,
      enabled,
      disabled,
  };

  /// PDO entry descriptor - runtime description of a field in domain data
  pub const PdoEntry = struct {
      name: []const u8,
      bit_offset: usize,
      bit_length: usize,
      direction: PdoDirection,
      current_value: [MAX_PDO_ENTRY_BYTES]u8,  // Raw bytes storing the current value
  };

  /// Domain layout - collection of PDO entry descriptors
  pub const DomainLayout = struct {
      entries: std.ArrayList(PdoEntry),

      pub fn init() DomainLayout {
          return .{
              .entries = std.ArrayList(PdoEntry){},
          };
      }

      pub fn deinit(self: *DomainLayout) void {
          // Free all entry names
          for (self.entries.items) |entry| {
              beam.allocator.free(entry.name);
          }
          self.entries.deinit(beam.allocator);
      }

      pub fn addEntry(self: *DomainLayout, name: []const u8, bit_offset: usize, bit_length: usize, direction: PdoDirection) !void {
          // Check for maximum entries limit to prevent unbounded growth
          if (self.entries.items.len >= MAX_ENTRIES_PER_DOMAIN) {
              return DomainError.TooManyEntries;
          }

          // Check for duplicate name
          if (self.findEntry(name)) |_| {
              return DomainError.DuplicateEntry;
          }

          // Check for overlapping bit ranges to prevent data corruption
          const entry_end = bit_offset + bit_length;
          for (self.entries.items) |existing| {
              const existing_end = existing.bit_offset + existing.bit_length;
              const overlaps = (bit_offset < existing_end) and (entry_end > existing.bit_offset);
              if (overlaps) {
                  return DomainError.OverlappingEntries;
              }
          }

          // Duplicate name string so we own the memory
          const owned_name = try beam.allocator.dupe(u8, name);
          errdefer beam.allocator.free(owned_name);  // Free on error

          try self.entries.append(beam.allocator, .{
              .name = owned_name,
              .bit_offset = bit_offset,
              .bit_length = bit_length,
              .direction = direction,
              .current_value = [_]u8{0} ** MAX_PDO_ENTRY_BYTES,  // Initialize to zero
          });
      }

      pub fn findEntry(self: *const DomainLayout, name: []const u8) ?PdoEntry {
          for (self.entries.items) |entry| {
              if (std.mem.eql(u8, entry.name, name)) {
                  return entry;
              }
          }
          return null;
      }

      /// Find PDO entry that contains the given bit offset
      pub fn findEntryByOffset(self: *const DomainLayout, bit_offset: usize) ?PdoEntry {
          for (self.entries.items) |entry| {
              const entry_end = entry.bit_offset + entry.bit_length;
              if (bit_offset >= entry.bit_offset and bit_offset < entry_end) {
                  return entry;
              }
          }
          return null;
      }

      /// Update the current_value field for an entry
      pub fn updateEntryValue(self: *DomainLayout, bit_offset: usize, value: [8]u8) void {
          for (self.entries.items) |*entry| {
              if (entry.bit_offset == bit_offset) {
                  entry.current_value = value;
                  return;
              }
          }
      }
  };

  /// Domain accessor - combines EtherCAT domain with runtime layout and cyclic configuration
  pub const DomainAccessor = struct {
      domain_ptr: usize,  // Store as usize to avoid C pointer in BEAM resource
      domain_name: beam.term,  // Domain name atom for routing (e.g., :default_domain)
      layout: DomainLayout,
      interval: u32,  // Interval multiplier for cyclic task
      data: []u8,       // Current cycle data (points to ecrt-managed memory)
      state: ecrt.ec_domain_state_t,  // Domain state for change detection
      mutex: std.Thread.Mutex,  // Protects current_value in entries
      cleaned_up: std.atomic.Value(bool),  // Atomic flag to prevent double-free

      pub fn init(domain: *ecrt.ec_domain_t, domain_name: beam.term, interval: u32) DomainAccessor {
          return .{
              .domain_ptr = @intFromPtr(domain),
              .domain_name = domain_name,
              .layout = DomainLayout.init(),
              .interval = interval,
              .data = &[_]u8{},       // Will be set in cyclic_task
              .state = std.mem.zeroes(ecrt.ec_domain_state_t),  // Initialize state
              .mutex = .{},
              .cleaned_up = std.atomic.Value(bool).init(false),
          };
      }

      pub fn deinit(self: *DomainAccessor) void {
          // Atomic swap to ensure single cleanup (prevents double-free)
          const was_cleaned = self.cleaned_up.swap(true, .acq_rel);
          if (was_cleaned) {
              return;  // Already cleaned up
          }
          self.layout.deinit();
      }

      /// Get the domain pointer with null validation
      pub fn getDomain(self: *const DomainAccessor) !*ecrt.ec_domain_t {
          if (self.domain_ptr == 0) {
              return DomainError.NullPointer;
          }
          return @ptrFromInt(self.domain_ptr);
      }

      /// Get the domain pointer without error checking (for internal use where validation is guaranteed)
      fn getDomainUnchecked(self: *const DomainAccessor) *ecrt.ec_domain_t {
          return @ptrFromInt(self.domain_ptr);
      }

      /// Initialize domain data pointer (called once during cyclic_task setup)
      pub fn initDomainData(self: *DomainAccessor) !void {
          const domain = try self.getDomain();
          const size = ecrt.ecrt_domain_size(domain);

          // Empty domains (no PDOs registered) have size 0 and null data pointer
          if (size == 0) {
              self.data = &[_]u8{};
              return;
          }

          const data_ptr = ecrt.ecrt_domain_data(domain);
          if (data_ptr == null) {
              return MasterError.InvalidDomainData;
          }

          // Memory for data is managed by ecrt.h
          self.data = data_ptr[0..size];
      }
  };

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



  // ============================================================================
  // MASTER OPERATIONS
  // ============================================================================
  //
  // ERROR HANDLING PHILOSOPHY (Elixir "Let It Crash"):
  //
  // 1. RECOVERABLE ERRORS → Return {:ok, result} | {:error, reason}
  //    - Network issues (slave not responding, link down)
  //    - Resource exhaustion (out of memory, no masters available)
  //    - Business logic failures (activation failed, domain creation failed)
  //    Examples: request_master, master_activate, get_master_state, master_get_slave
  //
  // 2. EXCEPTIONAL ERRORS → Raise (return Zig error with `!`)
  //    - Programming errors (invalid indices, null pointers)
  //    - Setup-time configuration errors (wrong PDO mapping)
  //    - Critical cyclic operation failures (receive/send in RT loop)
  //    Supervisor will restart the crashed process.
  //    Examples: introspection NIFs, slave config ops, cyclic RT operations
  //
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
  /// Returns :ok | {:error, :activate_error}
  pub fn master_activate(master: MasterResource) beam.term {
      const result = ecrt.ecrt_master_activate(master.unpack());
      if (result != 0) {
          return beam.make_error_pair(.activate_error, .{});
      }
      return beam.make(.ok, .{});
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
  /// Returns {:ok, master_state_t} | {:error, reason}
  pub fn get_master_state(master: MasterResource) beam.term {
      const master_state = do_get_master_state(master.unpack()) catch {
          return beam.make_error_pair(.master_not_found, .{});
      };
      return beam.make(.{ .ok, master_state }, .{});
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

  /// Create a new domain accessor with layout tracking
  /// Domains are used to group PDO registrations for efficient I/O
  /// Returns {:ok, domain_accessor_resource} | {:error, reason}
  pub fn master_create_domain(master: MasterResource, domain_name: beam.term, interval: u32) beam.term {
      const domain = ecrt.ecrt_master_create_domain(master.unpack()) orelse {
          return beam.make_error_pair(.domain_creation_failed, .{});
      };

      const accessor = beam.allocator.create(DomainAccessor) catch {
          return beam.make_error_pair(.out_of_memory, .{});
      };
      accessor.* = DomainAccessor.init(domain, domain_name, interval);

      const resource = DomainAccessorResource.create(accessor, .{}) catch {
          beam.allocator.destroy(accessor);
          return beam.make_error_pair(.resource_creation_failed, .{});
      };
      return beam.make(.{ .ok, resource }, .{});
  }

  /// Configure a slave device
  /// Returns {:ok, slave_config_resource} | {:error, :slave_config_error}
  pub fn master_slave_config(master: MasterResource, alias: u16, position: u16, vendor_id: u32, product_code: u32) beam.term {
      const slave_config = ecrt.ecrt_master_slave_config(master.unpack(), alias, position, vendor_id, product_code) orelse {
          return beam.make_error_pair(.slave_config_error, .{});
      };
      const resource = SlaveConfigResource.create(slave_config, .{}) catch {
          return beam.make_error_pair(.resource_creation_failed, .{});
      };
      return beam.make(.{ .ok, resource }, .{});
  }

  /// Get information about a slave at the given position
  /// Recoverable: Slave might not be responding (network issue)
  /// Returns {:ok, slave_info} | {:error, :get_slave_error}
  pub fn master_get_slave(master: MasterResource, slave_position: u16) beam.term {
      var slave_info: ecrt.ec_slave_info_t = undefined;
      const result = ecrt.ecrt_master_get_slave(master.unpack(), slave_position, &slave_info);
      if (result != 0) {
          return beam.make_error_pair(.get_slave_error, .{});
      }
      return beam.make(.{ .ok, slave_info }, .{});
  }

  /// Reset the master to initial state
  /// Let it crash: If reset fails, hardware is in undefined state and needs restart
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
  /// Let it crash: Invalid indices are programming errors
  pub fn master_get_sync_manager(master: MasterResource, slave_position: u16, sync_index: u8) !beam.term {
      var sync: ecrt.ec_sync_info_t = undefined;
      const result = ecrt.ecrt_master_get_sync_manager(master.unpack(), slave_position, sync_index, &sync);
      if (result != 0) return MasterError.GetSlaveError;
      return beam.make(.{ .index = sync.index, .dir = sync.dir, .n_pdos = sync.n_pdos, .watchdog_mode = sync.watchdog_mode }, .{});
  }

  /// Get PDO information for a slave
  /// Let it crash: Invalid indices are programming errors
  pub fn master_get_pdo(master: MasterResource, slave_position: u16, sync_index: u8, pos: u16) !beam.term {
      var pdo: ecrt.ec_pdo_info_t = undefined;
      const result = ecrt.ecrt_master_get_pdo(master.unpack(), slave_position, sync_index, pos, &pdo);
      if (result != 0) return MasterError.GetSlaveError;
      return beam.make(.{ .index = pdo.index, .n_entries = pdo.n_entries }, .{});
  }

  /// Get PDO entry information for a slave
  /// Let it crash: Invalid indices are programming errors
  pub fn master_get_pdo_entry(master: MasterResource, slave_position: u16, sync_index: u8, pdo_pos: u16, entry_pos: u16) !beam.term {
      var pdo_entry: ecrt.ec_pdo_entry_info_t = undefined;
      const result = ecrt.ecrt_master_get_pdo_entry(master.unpack(), slave_position, sync_index, pdo_pos, entry_pos, &pdo_entry);
      if (result != 0) return MasterError.GetSlaveError;
      return beam.make(pdo_entry, .{});
  }

  // ============================================================================
  // DOMAIN OPERATIONS
  // ============================================================================

  /// Process domain data after receiving frames
  pub fn domain_process(domain_accessor: DomainAccessorResource) !void {
      const accessor = domain_accessor.unpack();
      const domain = try accessor.getDomain();
      // Check return value for errors
      _ = ecrt.ecrt_domain_process(domain);
  }

  /// Queue domain data for sending
  pub fn domain_queue(domain_accessor: DomainAccessorResource) !void {
      const accessor = domain_accessor.unpack();
      const domain = try accessor.getDomain();
      // Check return value for errors
      _ = ecrt.ecrt_domain_queue(domain);
  }

  /// Get a boolean value from domain data at the specified bit offset
  pub fn get_domain_value_bool(domain_accessor: DomainAccessorResource, offset: usize) !bool {
      const accessor = domain_accessor.unpack();
      const domain = try accessor.getDomain();
      const data = ecrt.ecrt_domain_data(domain) orelse
          return DomainError.NullPointer;
      const domain_size = ecrt.ecrt_domain_size(domain);

      if (offset >= domain_size * 8) return DomainError.OutOfBounds;

      const byte_index = offset / 8;
      const bit_index = @as(u3, @intCast(offset % 8));
      return (data[byte_index] >> bit_index) & 1 != 0;
  }

  /// Write arbitrary bits to domain buffer at specified bit offset
  /// Used by cyclic_task to apply output events
  ///
  /// Handles bit-level writes that may span byte boundaries. PDO entries can be any bit size
  /// (1-64 bits) and start at any bit offset, requiring careful masking and shifting.
  ///
  /// Example: Writing 12 bits starting at bit offset 5 spans 3 bytes:
  ///   Byte 0: bits 5-7 (3 bits), Byte 1: bits 0-7 (8 bits), Byte 2: bits 0-0 (1 bit)
  fn write_bits_to_domain(data: []u8, bit_offset: usize, value_bytes: []const u8, bit_length: u8) !void {
      // Validate parameters upfront to prevent buffer overflow
      const end_bit = bit_offset + bit_length;
      const max_bit = data.len * 8;
      if (end_bit > max_bit) {
          return DomainError.OutOfBounds;
      }

      var bits_written: usize = 0;

      while (bits_written < bit_length) {
          // Calculate target position in domain buffer
          const current_bit_offset = bit_offset + bits_written;
          const byte_index = current_bit_offset / 8;
          const bit_index_usize = current_bit_offset % 8;
          const bit_index = @as(u3, @intCast(bit_index_usize));

          // Defensive check (should never fail after initial validation)
          std.debug.assert(byte_index < data.len);

          // Determine how many bits fit in current byte (may be partial)
          const bits_remaining_in_byte = 8 - bit_index_usize;
          const bits_to_write = @min(bit_length - bits_written, bits_remaining_in_byte);

          // Extract corresponding bits from source value
          const value_byte_index = bits_written / 8;
          const value_bit_index_usize = bits_written % 8;
          const value_bit_index = @as(u3, @intCast(value_bit_index_usize));

          // Bounds check for value_bytes
          if (value_byte_index >= value_bytes.len) {
              return DomainError.InvalidSize;
          }

          // Create mask for the bits we're writing (e.g., 0b00000111 for 3 bits)
          const mask = (@as(u8, 1) << @intCast(bits_to_write)) - 1;

          // Extract value bits and shift to target position in destination byte
          const value_bits = (value_bytes[value_byte_index] >> value_bit_index) & mask;
          const shifted_value = value_bits << bit_index;

          // Clear target bits, then OR in new value (preserves other bits in byte)
          const clear_mask = ~(mask << bit_index);
          data[byte_index] = (data[byte_index] & clear_mask) | shifted_value;

          bits_written += bits_to_write;
      }
  }

  /// Get the current state of the domain
  pub fn domain_state(domain_accessor: DomainAccessorResource) !beam.term {
      const accessor = domain_accessor.unpack();
      const domain = try accessor.getDomain();
      var state: ecrt.ec_domain_state_t = undefined;
      _ = ecrt.ecrt_domain_state(domain, &state);
      return beam.make(state, .{});
  }

  /// Get the size of the domain data in bytes
  pub fn get_domain_size(domain_accessor: DomainAccessorResource) !usize {
      const accessor = domain_accessor.unpack();
      const domain = try accessor.getDomain();
      return ecrt.ecrt_domain_size(domain);
  }



  // ============================================================================
  // TYPED ACCESSOR FUNCTIONS (Name-based access using layout)
  // ============================================================================

  /// Helper function to extract bits from domain data into a buffer
  fn extractBitsToBuffer(buffer: []u8, data: []const u8, bit_offset: usize, bit_length: usize) void {
      @memset(buffer, 0);
      var bits_read: usize = 0;
      var byte_idx = bit_offset / 8;
      var bit_idx = bit_offset % 8;
      var out_byte_idx: usize = 0;

      while (bits_read < bit_length and byte_idx < data.len and out_byte_idx < buffer.len) {
          const bits_in_byte = @min(8 - bit_idx, bit_length - bits_read);
          const mask: u8 = if (bits_in_byte >= 8) 0xFF else (@as(u8, 1) << @intCast(bits_in_byte)) - 1;
          const bits = (data[byte_idx] >> @intCast(bit_idx)) & mask;

          buffer[out_byte_idx] |= bits << @intCast(bits_read % 8);

          bits_read += bits_in_byte;
          byte_idx += 1;
          bit_idx = 0;
          if (bits_read % 8 == 0 and bits_read > 0) {
              out_byte_idx += 1;
          }
      }
  }

  /// Helper function to extract bits from domain data into typed result
  ///
  /// Reads bit_length bits starting at bit_offset and returns as type T.
  /// Handles multi-byte reads across byte boundaries.
  ///
  /// Example: Reading 12 bits at offset 5 from domain data:
  ///   Byte 0 bits 5-7 → result bits 0-2 (3 bits)
  ///   Byte 1 bits 0-7 → result bits 3-10 (8 bits)
  ///   Byte 2 bits 0-0 → result bits 11-11 (1 bit)
  fn extractBits(comptime T: type, data: []const u8, bit_offset: usize, bit_length: usize) T {
      var result: T = 0;
      var bits_read: usize = 0;
      var byte_idx = bit_offset / 8;
      var bit_idx = bit_offset % 8;

      while (bits_read < bit_length and byte_idx < data.len) {
          // Read as many bits as possible from current byte
          const bits_in_byte = @min(8 - bit_idx, bit_length - bits_read);
          const mask: u8 = if (bits_in_byte >= 8) 0xFF else (@as(u8, 1) << @intCast(bits_in_byte)) - 1;
          const bits = (data[byte_idx] >> @intCast(bit_idx)) & mask;

          // Accumulate bits into result at correct position
          result |= @as(T, bits) << @intCast(bits_read);

          bits_read += bits_in_byte;
          byte_idx += 1;
          bit_idx = 0;  // Subsequent bytes start at bit 0
      }

      return result;
  }

  /// Get a value from domain data by name, returns raw binary for driver decoding
  /// When called via Domain.get_pdo_value, the Slave will decode using the driver
  pub fn get_value(domain_accessor: DomainAccessorResource, name: []const u8) !beam.term {
      const accessor = domain_accessor.unpack();
      std.log.debug("get_value: looking up '{s}' in domain (data_len={}, entries={})", .{name, accessor.data.len, accessor.layout.entries.items.len});
      const entry = accessor.layout.findEntry(name) orelse {
          std.log.err("get_value: entry '{s}' not found", .{name});
          return DomainError.InvalidOffset;
      };

      // Use the cached data pointer from accessor instead of getting a fresh one
      // This ensures we read from the same memory that the cyclic task updates
      const data_slice = accessor.data;

      if (data_slice.len == 0) {
          // Domain not yet initialized by cyclic task - return zeros
          // This can happen during startup before cyclic_task calls initDomainData()
          const bin = try beam.allocator.alloc(u8, (entry.bit_length + 7) / 8);
          @memset(bin, 0);
          return beam.make(bin, .{});
      }

      // Calculate required bytes for the entry
      const required_bytes = (entry.bit_length + 7) / 8;

      // Extract bits from domain data into temporary buffer
      var buffer: [8]u8 = [_]u8{0} ** 8;
      extractBitsToBuffer(buffer[0..required_bytes], data_slice, entry.bit_offset, entry.bit_length);

      std.log.debug("get_value: '{s}' at bit_offset={} = {any}", .{name, entry.bit_offset, buffer[0..required_bytes]});

      // Return as Elixir binary for driver to decode (only the required bytes)
      const bin = try beam.allocator.alloc(u8, required_bytes);
      @memcpy(bin, buffer[0..required_bytes]);
      return beam.make(bin, .{});
  }

  /// Set a value - directly updates the entry's expected value from binary data
  /// The cyclic task will write this value to the domain buffer every cycle
  /// Encoding is handled by driver on Elixir side, this just stores the raw binary
  pub fn set_value(domain_accessor: DomainAccessorResource, name: []const u8, value: beam.term) !void {
      const accessor = domain_accessor.unpack();
      const entry = accessor.layout.findEntry(name) orelse
          return DomainError.InvalidOffset;

      const domain = try accessor.getDomain();
      const domain_size = ecrt.ecrt_domain_size(domain);
      const max_bit_offset = domain_size * 8;

      if (entry.bit_offset >= max_bit_offset) return DomainError.OutOfBounds;

      // Extract binary data from BEAM term
      const binary = try beam.get([]u8, value, .{});

      // Calculate required bytes based on entry bit length
      const required_bytes = (entry.bit_length + 7) / 8;
      if (binary.len != required_bytes) {
          return error.InvalidBinarySize;
      }

      // Copy binary data to entry's current_value buffer
      var value_data: [8]u8 = [_]u8{0} ** 8;
      @memcpy(value_data[0..binary.len], binary);

      std.log.debug("set_value: '{s}' at bit_offset={} = {any} (writing to domain buffer)", .{name, entry.bit_offset, binary});

      // Write directly to domain buffer
      write_bits_to_domain(accessor.data, entry.bit_offset, value_data[0..binary.len], @intCast(entry.bit_length)) catch |err| {
          std.log.err("set_value: Failed to write bits to domain: {}", .{err});
          return err;
      };

      std.log.debug("set_value: successfully wrote to domain buffer", .{});

      // Also update the expected value in the entry (thread-safe)
      accessor.mutex.lock();
      defer accessor.mutex.unlock();
      accessor.layout.updateEntryValue(entry.bit_offset, value_data);
  }

  // ============================================================================
  // SLAVE CONFIGURATION OPERATIONS
  // ============================================================================
  //
  // Let it crash: All configuration errors are programming bugs.
  // These must be called before master activation with correct parameters.
  // If they fail, the supervisor will restart and configuration can be fixed.
  //
  // ============================================================================

  /// Configure a sync manager for the slave
  /// Let it crash: Invalid configuration is a programming error
  pub fn slave_config_sync_manager(slave_config: SlaveConfigResource, sync_index: u8, direction: PdoDirection, watchdog_mode: WatchdogMode) !void {
      const result = ecrt.ecrt_slave_config_sync_manager(slave_config.unpack(), sync_index, @intFromEnum(direction), @intFromEnum(watchdog_mode));
      if (result != 0) return MasterError.SlaveConfigError;
  }

  /// Add a PDO to the sync manager's PDO assignment
  /// Let it crash: Invalid PDO assignment is a programming error
  pub fn slave_config_pdo_assign_add(slave_config: SlaveConfigResource, sync_index: u8, index: u16) !void {
      const result = ecrt.ecrt_slave_config_pdo_assign_add(slave_config.unpack(), sync_index, index);
      if (result != 0) return MasterError.SlaveConfigError;
  }

  /// Clear the sync manager's PDO assignment
  /// Let it crash: Invalid sync manager is a programming error
  pub fn slave_config_pdo_assign_clear(slave_config: SlaveConfigResource, sync_index: u8) !void {
      const result = ecrt.ecrt_slave_config_pdo_assign_clear(slave_config.unpack(), sync_index);
      if (result != 0) return MasterError.SlaveConfigError;
  }

  /// Add a PDO entry to a PDO's mapping
  /// Let it crash: Invalid PDO mapping is a programming error
  pub fn slave_config_pdo_mapping_add(slave_config: SlaveConfigResource, pdo_index: u16, entry_index: u16, entry_subindex: u8, entry_bit_length: u8) !void {
      const result = ecrt.ecrt_slave_config_pdo_mapping_add(slave_config.unpack(), pdo_index, entry_index, entry_subindex, entry_bit_length);
      if (result != 0) return MasterError.SlaveConfigError;
  }

  /// Clear a PDO's mapping
  /// Let it crash: Invalid PDO index is a programming error
  pub fn slave_config_pdo_mapping_clear(slave_config: SlaveConfigResource, pdo_index: u16) !void {
      const result = ecrt.ecrt_slave_config_pdo_mapping_clear(slave_config.unpack(), pdo_index);
      if (result != 0) return MasterError.SlaveConfigError;
  }

  /// Register a PDO entry for process data exchange and add to domain layout
  /// Let it crash: Invalid PDO entry configuration is a programming error
  /// Returns the offset in bits within the domain data
  pub fn slave_config_reg_pdo_entry(
      slave_config: SlaveConfigResource,
      name: []const u8,
      entry_index: u16,
      entry_subindex: u8,
      bit_length: usize,
      domain_accessor: DomainAccessorResource,
      direction: PdoDirection
  ) !usize {
      const accessor = domain_accessor.unpack();
      var bit_position: c_uint = 0;
      const domain = try accessor.getDomain();
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry(
          slave_config.unpack(),
          entry_index,
          entry_subindex,
          domain,
          &bit_position
      );

      if (result >= 0) {
          const bit_offset = @as(usize, @intCast(result)) * 8 + bit_position;

          // Add entry to domain layout
          try accessor.layout.addEntry(name, bit_offset, bit_length, direction);

          return bit_offset;
      } else {
          return MasterError.PdoRegError;
      }
  }

  // ============================================================================
  // SDO CONFIGURATION OPERATIONS
  // ============================================================================

  /// Configure an SDO (Service Data Object) for a slave (pre-activation only).
  ///
  /// Queues an SDO download that will be executed during slave configuration
  /// (typically at master activation). The configuration persists and is
  /// automatically re-applied if the slave reboots.
  ///
  /// Let it crash: Invalid SDO configuration is a programming error
  /// MUST be called BEFORE ecrt_master_activate(). Errors are asynchronous.
  pub fn slave_config_sdo(
      slave_config: SlaveConfigResource,
      sdo_index: u16,
      sdo_subindex: u8,
      data: beam.term
  ) !void {
      const binary = try beam.get([]u8, data, .{});

      const result = ecrt.ecrt_slave_config_sdo(
          slave_config.unpack(),
          sdo_index,
          sdo_subindex,
          binary.ptr,
          binary.len
      );

      if (result < 0) {
          return MasterError.SlaveConfigError;
      }
  }

  // ============================================================================
  // THREADED OPERATIONS
  // ============================================================================

  /// Main cyclic task for EtherCAT communication
  ///
  /// Runs in a separate OS thread with microsecond-precision timing.
  ///
  /// Cycle sequence (deterministic, repeats at `interval` µs):
  ///   1. Sync application time
  ///   2. Receive frames (slave → master)
  ///   3. Process domains, detect changes, send notifications
  ///   4. Check master state changes
  ///   5. Queue domain outputs (if interval reached)
  ///   6. Send frames (master → slave)
  ///   7. Sleep to maintain precise cycle time
  ///
  /// Change detection: Compares domain buffer with stored values, notifies BEAM
  /// processes for inputs. For outputs, writes stored values to domain buffer.
  ///
  /// BEAM integration: Yields at configurable intervals to prevent scheduler starvation.
  ///
  /// ## Parameters
  /// - `master_pid` - PID of the master process
  /// - `master_resource` - Master resource reference
  /// - `domain_accessors` - List of domain accessor resources
  /// - `interval` - Cyclic task interval in microseconds
  /// - `nif_yield_interval` - Yielding interval in microseconds (default: 100_000 = 100ms)
  pub fn cyclic_task(master_pid: beam.pid, master_resource: MasterResource, domain_accessors: []DomainAccessorResource, interval: u64, nif_yield_interval: u64) !void {
      std.log.info("Cyclic task started: interval={}µs, yield_interval={}µs, domains={}", .{interval, nif_yield_interval, domain_accessors.len});

      const master = master_resource.unpack();
      var master_state: master_state_t = undefined;
      var prev_master_state: master_state_t = undefined;
      const yield_interval = @divTrunc(nif_yield_interval, interval); // Calculate yield interval in cycles

      // Initialize domain data pointers for all domain accessors
      for (domain_accessors) |domain_accessor_resource| {
          const accessor = domain_accessor_resource.unpack();
          try accessor.initDomainData();
          std.log.info("Domain initialized: data_len={}", .{accessor.data.len});
      }

      var counter: u32 = 0;

      // Main cyclic loop with deterministic timing
      var next_cycle_time: i128 = std.time.nanoTimestamp();
      const cycle_period_ns: i128 = @intCast(interval * std.time.ns_per_us);
      // FIX C2: Initialize with actual monotonic time, not zero
      var cycle_start_time: u64 = @intCast(std.time.nanoTimestamp());

      std.log.info("Entering main cyclic loop", .{});

      while (true) {
          // Debug: log first few cycles then every 100
          if (counter < 5 or counter % 100 == 0) {
              std.log.debug("Cyclic task running: cycle={}", .{counter});
          }
          // 1. Set application time (synchronize with master)
          // Use wrapping add to handle overflow gracefully after 584 years
          cycle_start_time +%= (interval * std.time.ns_per_us);
          _ = ecrt.ecrt_master_application_time(master, cycle_start_time);

          // 2. Receive frames from network (contains slave responses with input data)
          _ = ecrt.ecrt_master_receive(master);

          // 3. Process domains
          for (domain_accessors) |domain_accessor_resource| {
              const accessor = domain_accessor_resource.unpack();
              var new_state: ecrt.ec_domain_state_t = undefined;

              // Process domain data (updates buffer from received frame)
              // Use Unchecked variant: domain is guaranteed valid in cyclic_task
              _ = ecrt.ecrt_domain_process(accessor.getDomainUnchecked());

              // Debug: log domain buffer contents first few cycles then every 100
              if ((counter < 5 or counter % 100 == 0) and accessor.data.len > 0) {
                  std.log.debug("Cycle {}: domain buffer (first 4 bytes) = {any}", .{counter, accessor.data[0..@min(4, accessor.data.len)]});
              }

              _ = ecrt.ecrt_domain_state(accessor.getDomainUnchecked(), &new_state);

              // Notify working counter changes
              if (new_state.working_counter != accessor.state.working_counter) {
                  _ = try beam.send(master_pid, .{ .wc_changed, accessor.domain_name, new_state.working_counter }, .{});
              }

              // Notify state changes
              if (new_state.wc_state != accessor.state.wc_state) {
                  _ = try beam.send(master_pid, .{ .state_changed, accessor.domain_name, new_state.wc_state }, .{});
              }

              // FIX C1: Acquire mutex BEFORE reading domain data to prevent race condition
              // This protects against concurrent set_value() calls modifying current_value
              accessor.mutex.lock();
              defer accessor.mutex.unlock();

              for (accessor.layout.entries.items) |*entry| {
                  // Extract current value from domain data into temp buffer
                  var domain_value: [MAX_PDO_ENTRY_BYTES]u8 = [_]u8{0} ** MAX_PDO_ENTRY_BYTES;
                  extractBitsToBuffer(&domain_value, accessor.data, entry.bit_offset, entry.bit_length);

                  // Compare with stored current_value
                  const byte_count = (entry.bit_length + 7) / 8;
                  var changed = false;
                  var i: usize = 0;
                  while (i < byte_count and i < MAX_PDO_ENTRY_BYTES) : (i += 1) {
                      if (domain_value[i] != entry.current_value[i]) {
                          changed = true;
                          break;
                      }
                  }

                  if (changed) {
                      if (entry.direction == .input) {
                          // Input changed: extract raw binary and notify
                          const required_bytes = (entry.bit_length + 7) / 8;
                          var buffer: [MAX_PDO_ENTRY_BYTES]u8 = [_]u8{0} ** MAX_PDO_ENTRY_BYTES;
                          extractBitsToBuffer(buffer[0..required_bytes], accessor.data, entry.bit_offset, entry.bit_length);

                          // Send to Master with full routing context: domain_name + unique_name (slave:pdo:entry)
                          _ = try beam.send(master_pid, .{ .data_changed, accessor.domain_name, entry.name, buffer[0..required_bytes] }, .{});

                          // Update stored value
                          entry.current_value = domain_value;
                      } else {
                          // Output changed: write current_value to domain and notify
                          write_bits_to_domain(accessor.data, entry.bit_offset, &entry.current_value, @intCast(entry.bit_length)) catch |err| {
                              std.log.err("Failed to write bits to domain: {}", .{err});
                              continue;
                          };

                          const required_bytes = (entry.bit_length + 7) / 8;
                          _ = try beam.send(master_pid, .{ .output_changed, accessor.domain_name, entry.name, entry.current_value[0..required_bytes] }, .{});
                      }
                  }
              }

              // Update state for next iteration
              accessor.state = new_state;
          }

          // Step 4: Check and notify master state changes
          master_state = try do_get_master_state(master);

          if (!std.meta.eql(prev_master_state, master_state)) {
              _ = try beam.send(master_pid, .{ .master_state_changed, master_state }, .{});
          }

          prev_master_state = master_state;

          // Step 5: Queue domain outputs every cycle
          // (accessor.interval is in microseconds but not used for queueing frequency)
          for (domain_accessors) |domain_accessor_resource| {
              const accessor = domain_accessor_resource.unpack();
              _ = ecrt.ecrt_domain_queue(accessor.getDomainUnchecked());
              if (counter % 100 == 0) {
                  std.log.debug("Cycle {}: queued domain", .{counter});
              }
          }

          // Step 6: Send queued frames to network
          _ = ecrt.ecrt_master_send(master);

          // Step 7: Deterministic sleep to maintain exact cycle rate
          next_cycle_time += cycle_period_ns;
          const now = std.time.nanoTimestamp();
          const sleep_ns = next_cycle_time - now;

          if (sleep_ns > 0) {
              std.Thread.sleep(@intCast(sleep_ns));
          } else {
              // FIX H3: Cycle overrun detected - notify master process
              const overrun_us: u64 = @intCast(@divTrunc(-sleep_ns, std.time.ns_per_us));
              std.log.warn("Cycle overrun: {d}µs (cycle {d})", .{overrun_us, counter});

              // Notify master process of overrun for telemetry/monitoring
              _ = beam.send(master_pid, .{ .cycle_overrun, overrun_us, counter }, .{}) catch |err| {
                  std.log.err("Failed to send overrun notification: {}", .{err});
              };

              // Adaptive recovery: skip cycles if severely overrun (> 50% of cycle period)
              const overrun_ns: u64 = @intCast(-sleep_ns);
              const half_cycle: u64 = @intCast(@divTrunc(cycle_period_ns, 2));
              if (overrun_ns > half_cycle) {
                  const cycles_to_skip: u32 = @intCast(@divTrunc(overrun_ns, cycle_period_ns));
                  next_cycle_time += @as(i128, @intCast(cycles_to_skip)) * cycle_period_ns;
                  std.log.warn("Skipping {d} cycles to resync", .{cycles_to_skip});
              }
          }

          // Yield to BEAM scheduler periodically
          if (counter % yield_interval == 0) {
              beam.yield() catch {
                  // FIX H4: Clean up all resources before returning
                  for (domain_accessors) |domain_accessor_resource| {
                      const accessor = domain_accessor_resource.unpack();
                      accessor.deinit();  // Frees layout and entry names
                      domain_accessor_resource.release();
                  }
                  master_resource.release();

                  try beam.send(master_pid, .cyclic_task_died, .{});
                  return;
              };
          }

          counter +%= 1; // Wrapping increment
      }
  }
  """
end
