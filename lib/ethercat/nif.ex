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
      get_value: [],
      set_value: [],
      domain_set_pid: [],
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
  };

  const MemoryError = error{
      OutOfMemory,
      AllocationFailed,
  };

  // ============================================================================
  // TYPE DEFINITIONS
  // ============================================================================

  /// PDO entry data types
  pub const PdoEntryType = enum {
      bool,
      int8,
      uint8,
      int16,
      uint16,
      int32,
      uint32,
      int64,
      uint64,
  };

  /// PDO entry descriptor - runtime description of a field in domain data
  pub const PdoEntry = struct {
      name: []const u8,
      entry_type: PdoEntryType,
      bit_offset: usize,
      bit_length: usize,
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

      pub fn addEntry(self: *DomainLayout, name: []const u8, entry_type: PdoEntryType, bit_offset: usize, bit_length: usize) !void {
          // Duplicate name string so we own the memory
          const owned_name = try beam.allocator.dupe(u8, name);
          try self.entries.append(beam.allocator, .{
              .name = owned_name,
              .entry_type = entry_type,
              .bit_offset = bit_offset,
              .bit_length = bit_length,
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
  };

  /// Domain accessor - combines EtherCAT domain with runtime layout and cyclic configuration
  pub const DomainAccessor = struct {
      domain_ptr: usize,  // Store as usize to avoid C pointer in BEAM resource
      layout: DomainLayout,
      pid: beam.pid,
      interval: u32,  // Interval multiplier for cyclic task
      prev_data: []u8,  // Previous cycle data for change detection
      data: []u8,       // Current cycle data (points to ecrt-managed memory)

      pub fn init(domain: *ecrt.ec_domain_t, pid: beam.pid, interval: u32) DomainAccessor {
          return .{
              .domain_ptr = @intFromPtr(domain),
              .layout = DomainLayout.init(),
              .pid = pid,
              .interval = interval,
              .prev_data = &[_]u8{},  // Will be allocated in cyclic_task
              .data = &[_]u8{},       // Will be set in cyclic_task
          };
      }

      pub fn deinit(self: *DomainAccessor) void {
          self.layout.deinit();
          if (self.prev_data.len > 0) {
              beam.allocator.free(self.prev_data);
          }
      }

      pub fn setPid(self: *DomainAccessor, pid: beam.pid) void {
          self.pid = pid;
      }

      /// Get the domain pointer
      pub fn getDomain(self: *const DomainAccessor) *ecrt.ec_domain_t {
          return @ptrFromInt(self.domain_ptr);
      }

      /// Initialize change tracking buffers (called once during cyclic_task setup)
      pub fn initChangeTracking(self: *DomainAccessor) !void {
          const domain = self.getDomain();
          const size = ecrt.ecrt_domain_size(domain);
          const data_ptr = ecrt.ecrt_domain_data(domain);

          if (data_ptr == null) {
              return error.InvalidDomainData;
          }

          // Memory for data is managed by ecrt.h
          self.data = data_ptr[0..size];

          // Allocate our own buffer for tracking previous data
          self.prev_data = try beam.allocator.alloc(u8, size);
          @memcpy(self.prev_data, self.data);
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



  /// Output event for queuing domain value changes
  /// Handles arbitrary bit-aligned writes for all primitive types
  const OutputEvent = struct {
      domain_ptr: usize,      // Address of domain to match against DomainItem
      bit_offset: usize,      // Bit offset in domain (same as used in get/set functions)
      data: [8]u8,            // Raw value bytes (little-endian, right-aligned)
      bit_length: u8,         // Number of bits (1 for bool, 32 for u32, etc.)
  };

  /// Global event queue for output writes (single-writer from Elixir, single-reader from cyclic_task)
  /// Initialized in master_activate, before cyclic_task can run
  var output_events_mutex: std.Thread.Mutex = .{};
  var output_events: std.ArrayList(OutputEvent) = undefined;



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

      // Initialize output event queue (required before cyclic_task starts)
      output_events = std.ArrayList(OutputEvent){};
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

  /// Create a new domain accessor with layout tracking
  /// Domains are used to group PDO registrations for efficient I/O
  pub fn master_create_domain(master: MasterResource, pid: beam.pid, interval: u32) !DomainAccessorResource {
      const domain = ecrt.ecrt_master_create_domain(master.unpack()) orelse
          return MasterError.MasterNotFound;

      const accessor = try beam.allocator.create(DomainAccessor);
        accessor.* = DomainAccessor.init(domain, pid, interval);

      return DomainAccessorResource.create(accessor, .{});
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
  pub fn domain_process(domain_accessor: DomainAccessorResource) !void {
      const accessor = domain_accessor.unpack();
      _ = ecrt.ecrt_domain_process(accessor.getDomain());
  }

  /// Queue domain data for sending
  pub fn domain_queue(domain_accessor: DomainAccessorResource) !void {
      const accessor = domain_accessor.unpack();
        _ = ecrt.ecrt_domain_queue(accessor.getDomain());
  }

  /// Get a boolean value from domain data at the specified bit offset
  pub fn get_domain_value_bool(domain_accessor: DomainAccessorResource, offset: usize) !bool {
      const accessor = domain_accessor.unpack();
      const data = ecrt.ecrt_domain_data(accessor.getDomain()) orelse
          return DomainError.NullPointer;
        const domain_size = ecrt.ecrt_domain_size(accessor.getDomain());

      if (offset >= domain_size * 8) return DomainError.OutOfBounds;

      const byte_index = offset / 8;
      const bit_index = @as(u3, @intCast(offset % 8));
      return (data[byte_index] >> bit_index) & 1 != 0;
  }

  /// Write arbitrary bits to domain buffer at specified bit offset
  /// Used by cyclic_task to apply output events
  fn write_bits_to_domain(data: []u8, bit_offset: usize, value_bytes: []const u8, bit_length: u8) void {
      var bits_written: usize = 0;

      while (bits_written < bit_length) {
          const current_bit_offset = bit_offset + bits_written;
          const byte_index = current_bit_offset / 8;
          const bit_index_usize = current_bit_offset % 8;
            const bit_index = @as(u3, @intCast(bit_index_usize));

          // How many bits can we write in this byte?
          const bits_remaining_in_byte = 8 - bit_index_usize;
          const bits_to_write = @min(bit_length - bits_written, bits_remaining_in_byte);

          // Extract bits from value_bytes
          const value_byte_index = bits_written / 8;
            const value_bit_index_usize = bits_written % 8;
          const value_bit_index = @as(u3, @intCast(value_bit_index_usize));

          // Create mask for bits we're writing
          const mask = (@as(u8, 1) << @intCast(bits_to_write)) - 1;

          // Extract value bits and shift to target position
          const value_bits = (value_bytes[value_byte_index] >> value_bit_index) & mask;
          const shifted_value = value_bits << bit_index;

          // Clear target bits and write new value
          const clear_mask = ~(mask << bit_index);
          data[byte_index] = (data[byte_index] & clear_mask) | shifted_value;

          bits_written += bits_to_write;
      }
  }

  /// Set a boolean value in domain data at the specified bit offset
  /// Appends an event to the queue; cyclic_task will apply it before queue_domains
  pub fn set_domain_value_bool(domain_accessor: DomainAccessorResource, offset: usize, value: bool) !void {
      const accessor = domain_accessor.unpack();
      const domain_size = ecrt.ecrt_domain_size(accessor.getDomain());

      if (offset >= domain_size * 8) return DomainError.OutOfBounds;

      // Create event with bool value (1 bit)
      var event_data: [8]u8 = [_]u8{0} ** 8;
      event_data[0] = if (value) 1 else 0;

      const event = OutputEvent{
          .domain_ptr = accessor.domain_ptr,
          .bit_offset = offset,
          .data = event_data,
          .bit_length = 1,
      };

      // Append to event queue (single writer, so lock is brief)
      output_events_mutex.lock();
      defer output_events_mutex.unlock();
      try output_events.append(beam.allocator, event);
  }

  /// Get the current state of the domain
  pub fn domain_state(domain_accessor: DomainAccessorResource) !beam.term {
      const accessor = domain_accessor.unpack();
      var state: ecrt.ec_domain_state_t = undefined;
      _ = ecrt.ecrt_domain_state(accessor.getDomain(), &state);
      return beam.make(state, .{});
  }

  /// Get the size of the domain data in bytes
  pub fn get_domain_size(domain_accessor: DomainAccessorResource) !usize {
      const accessor = domain_accessor.unpack();
        return ecrt.ecrt_domain_size(accessor.getDomain());
  }

  /// Set the process ID for the domain accessor
  pub fn domain_set_pid(domain_accessor: DomainAccessorResource, pid: beam.pid) !void {
      const accessor = domain_accessor.unpack();
      accessor.setPid(pid);
  }

  // ============================================================================
  // TYPED ACCESSOR FUNCTIONS (Name-based access using layout)
  // ============================================================================

  /// Helper function to extract bits from domain data
  fn extractBits(comptime T: type, data: []const u8, bit_offset: usize, bit_length: usize) T {
      var result: T = 0;
      var bits_read: usize = 0;
      var byte_idx = bit_offset / 8;
      var bit_idx = bit_offset % 8;

      while (bits_read < bit_length and byte_idx < data.len) {
          const bits_in_byte = @min(8 - bit_idx, bit_length - bits_read);
          const mask = (@as(u8, 1) << @intCast(bits_in_byte)) - 1;
          const bits = (data[byte_idx] >> @intCast(bit_idx)) & mask;

          result |= @as(T, bits) << @intCast(bits_read);

          bits_read += bits_in_byte;
          byte_idx += 1;
          bit_idx = 0;
      }

      return result;
  }

  /// Extract value from PDO entry based on its type
  fn extractEntryValue(entry: PdoEntry, data: []const u8) !beam.term {
      return switch (entry.entry_type) {
          .bool => {
              const byte_index = entry.bit_offset / 8;
              const bit_index = @as(u3, @intCast(entry.bit_offset % 8));
              const value = (data[byte_index] >> bit_index) & 1 != 0;
              return beam.make(value, .{});
          },
          .uint8 => beam.make(extractBits(u8, data, entry.bit_offset, entry.bit_length), .{}),
          .int8 => beam.make(@as(i8, @bitCast(extractBits(u8, data, entry.bit_offset, entry.bit_length))), .{}),
          .uint16 => beam.make(extractBits(u16, data, entry.bit_offset, entry.bit_length), .{}),
          .int16 => beam.make(@as(i16, @bitCast(extractBits(u16, data, entry.bit_offset, entry.bit_length))), .{}),
          .uint32 => beam.make(extractBits(u32, data, entry.bit_offset, entry.bit_length), .{}),
          .int32 => beam.make(@as(i32, @bitCast(extractBits(u32, data, entry.bit_offset, entry.bit_length))), .{}),
          .uint64 => beam.make(extractBits(u64, data, entry.bit_offset, entry.bit_length), .{}),
          .int64 => beam.make(@as(i64, @bitCast(extractBits(u64, data, entry.bit_offset, entry.bit_length))), .{}),
      };
  }

  /// Get a value from domain data by name
  pub fn get_value(domain_accessor: DomainAccessorResource, name: []const u8) !beam.term {
      const accessor = domain_accessor.unpack();
      const entry = accessor.layout.findEntry(name) orelse
          return DomainError.InvalidOffset;

      const data = ecrt.ecrt_domain_data(accessor.getDomain()) orelse
          return DomainError.NullPointer;
      const domain_size = ecrt.ecrt_domain_size(accessor.getDomain());
      const data_slice = data[0..domain_size];

      return switch (entry.entry_type) {
          .bool => {
              const byte_index = entry.bit_offset / 8;
              const bit_index = @as(u3, @intCast(entry.bit_offset % 8));
              const value = (data_slice[byte_index] >> bit_index) & 1 != 0;
              return beam.make(value, .{});
          },
          .uint8 => beam.make(extractBits(u8, data_slice, entry.bit_offset, entry.bit_length), .{}),
          .int8 => beam.make(@as(i8, @bitCast(extractBits(u8, data_slice, entry.bit_offset, entry.bit_length))), .{}),
          .uint16 => beam.make(extractBits(u16, data_slice, entry.bit_offset, entry.bit_length), .{}),
          .int16 => beam.make(@as(i16, @bitCast(extractBits(u16, data_slice, entry.bit_offset, entry.bit_length))), .{}),
          .uint32 => beam.make(extractBits(u32, data_slice, entry.bit_offset, entry.bit_length), .{}),
          .int32 => beam.make(@as(i32, @bitCast(extractBits(u32, data_slice, entry.bit_offset, entry.bit_length))), .{}),
          .uint64 => beam.make(extractBits(u64, data_slice, entry.bit_offset, entry.bit_length), .{}),
          .int64 => beam.make(@as(i64, @bitCast(extractBits(u64, data_slice, entry.bit_offset, entry.bit_length))), .{}),
      };
  }

  /// Set a value in domain data by name
  /// Appends an event to the queue; cyclic_task will apply it before queue_domains
  pub fn set_value(domain_accessor: DomainAccessorResource, name: []const u8, value: beam.term) !void {
      const accessor = domain_accessor.unpack();
      const entry = accessor.layout.findEntry(name) orelse
          return DomainError.InvalidOffset;

      const domain_size = ecrt.ecrt_domain_size(accessor.getDomain());
      const max_bit_offset = domain_size * 8;

      if (entry.bit_offset >= max_bit_offset) return DomainError.OutOfBounds;

      var event_data: [8]u8 = [_]u8{0} ** 8;

      // Convert the value based on type
      switch (entry.entry_type) {
          .bool => {
              const val = try beam.get(bool, value, .{});
              event_data[0] = if (val) 1 else 0;
          },
          .uint8 => {
              const val = try beam.get(u8, value, .{});
              event_data[0] = val;
          },
          .int8 => {
              const val = try beam.get(i8, value, .{});
              event_data[0] = @bitCast(val);
          },
          .uint16 => {
              const val = try beam.get(u16, value, .{});
              @memcpy(event_data[0..2], std.mem.asBytes(&val));
          },
          .int16 => {
              const val = try beam.get(i16, value, .{});
              @memcpy(event_data[0..2], std.mem.asBytes(&val));
          },
          .uint32 => {
              const val = try beam.get(u32, value, .{});
              @memcpy(event_data[0..4], std.mem.asBytes(&val));
          },
          .int32 => {
              const val = try beam.get(i32, value, .{});
              @memcpy(event_data[0..4], std.mem.asBytes(&val));
          },
          .uint64 => {
              const val = try beam.get(u64, value, .{});
              @memcpy(event_data[0..8], std.mem.asBytes(&val));
          },
          .int64 => {
              const val = try beam.get(i64, value, .{});
              @memcpy(event_data[0..8], std.mem.asBytes(&val));
          },
      }

      const event = OutputEvent{
          .domain_ptr = accessor.domain_ptr,
          .bit_offset = entry.bit_offset,
          .data = event_data,
          .bit_length = @intCast(entry.bit_length),
      };

      // Append to event queue
      output_events_mutex.lock();
      defer output_events_mutex.unlock();
      try output_events.append(beam.allocator, event);
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

  /// Register a PDO entry for process data exchange and add to domain layout
  /// Returns the offset in bits within the domain data
  pub fn slave_config_reg_pdo_entry(
      slave_config: SlaveConfigResource,
      name: []const u8,
      entry_type: PdoEntryType,
      entry_index: u16,
      entry_subindex: u8,
      bit_length: usize,
      domain_accessor: DomainAccessorResource
  ) !usize {
      const accessor = domain_accessor.unpack();
      var bit_position: c_uint = 0;
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry(
          slave_config.unpack(),
          entry_index,
          entry_subindex,
          accessor.getDomain(),
          &bit_position
      );

      if (result >= 0) {
          const bit_offset = @as(usize, @intCast(result)) * 8 + bit_position;

          // Add entry to domain layout
          try accessor.layout.addEntry(name, entry_type, bit_offset, bit_length);

          return bit_offset;
      } else {
          return MasterError.PdoRegError;
      }
  }

  /// Register a PDO entry by position and add to domain layout
  /// Returns the offset in bits within the domain data
  pub fn slave_config_reg_pdo_entry_pos(
      slave_config: SlaveConfigResource,
      name: []const u8,
      entry_type: PdoEntryType,
      sync_index: u8,
      pdo_pos: c_uint,
      entry_pos: c_uint,
      bit_length: usize,
      domain_accessor: DomainAccessorResource
  ) !usize {
      const accessor = domain_accessor.unpack();
      var bit_position: c_uint = 0;
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry_pos(
          slave_config.unpack(),
          sync_index,
          pdo_pos,
          entry_pos,
          accessor.getDomain(),
          &bit_position
      );

      if (result >= 0) {
          const bit_offset = @as(usize, @intCast(result)) * 8 + bit_position;

          // Add entry to domain layout
          try accessor.layout.addEntry(name, entry_type, bit_offset, bit_length);

          return bit_offset;
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
  pub fn cyclic_task(master_pid: beam.pid, master_resource: MasterResource, domain_accessors: []DomainAccessorResource, interval: u64) !void {
      const master = master_resource.unpack();
      var master_state: master_state_t = undefined;
      var prev_master_state: master_state_t = undefined;
      const yield_interval = @divTrunc(100_000, interval); // Yield every 100ms

      // Initialize change tracking for all domain accessors
      // Also track domain state per accessor (can't store in resource due to C struct)
      var domain_states = std.ArrayList(ecrt.ec_domain_state_t){};
      defer domain_states.deinit(beam.allocator);

      for (domain_accessors) |domain_accessor_resource| {
          const accessor = domain_accessor_resource.unpack();
          try accessor.initChangeTracking();
          try domain_states.append(beam.allocator, undefined);
      }

      defer {
          beam.send(master_pid, .killed, .{}) catch {};
      }

      var counter: u32 = 0;

      // Track changed entries by name to avoid duplicates
      var changed_entries = std.StringHashMap(void).init(beam.allocator);
      defer changed_entries.deinit();

      // Main cyclic loop with deterministic timing
      var next_cycle_time: i128 = std.time.nanoTimestamp();
      const cycle_period_ns: i128 = @intCast(interval * std.time.ns_per_us);
      var cycle_start_time: u64 = 0;

      while (true) {
          // 1. Set application time (synchronize with master)
          cycle_start_time = cycle_start_time + (interval * std.time.ns_per_us);
          _ = ecrt.ecrt_master_application_time(master, cycle_start_time);

          // 2. Receive frames from network (contains slave responses with input data)
          _ = ecrt.ecrt_master_receive(master);

          // 3. Process domains
          for (domain_accessors, domain_states.items) |domain_accessor_resource, *prev_state| {
              const accessor = domain_accessor_resource.unpack();
              var state: ecrt.ec_domain_state_t = undefined;

              // Process domain data (updates buffer from received frame)
                _ = ecrt.ecrt_domain_process(accessor.getDomain());

                _ = ecrt.ecrt_domain_state(accessor.getDomain(), &state);

              // Notify working counter changes
              if (state.working_counter != prev_state.working_counter) {
                  _ = try beam.send(accessor.pid, .{ .wc_changed, state.working_counter }, .{});
              }

              // Notify state changes
              if (state.wc_state != prev_state.wc_state) {
                  _ = try beam.send(accessor.pid, .{ .state_changed, state.wc_state }, .{});
              }

              // Detect data changes at bit level and map to PDO entries
              changed_entries.clearRetainingCapacity();

              for (accessor.data, accessor.prev_data, 0..) |byte_a, byte_b, byte_i| {
                  const diff = byte_a ^ byte_b; // XOR to find differing bits

                  if (diff != 0) {
                      var bit_mask = diff;

                      while (bit_mask != 0) {
                          const bit_pos = @ctz(bit_mask); // Count trailing zeros
                          const bit_offset = byte_i * 8 + bit_pos;

                            // Find the PDO entry that contains this bit
                          if (accessor.layout.findEntryByOffset(bit_offset)) |entry| {
                              // Add to changed entries set (deduplicates automatically)
                              try changed_entries.put(entry.name, {});
                          }

                          bit_mask &= bit_mask - 1; // Clear least significant set bit
                      }
                  }
              }

              // Notify entry changes if any detected
                if (changed_entries.count() > 0) {
                  @memcpy(accessor.prev_data, accessor.data);

                  // Build list of {name, value} tuples for changed entries
                  var changes = std.ArrayList(beam.term){};
                  defer changes.deinit(beam.allocator);

                  var iter = changed_entries.keyIterator();
                  while (iter.next()) |entry_name| {
                      if (accessor.layout.findEntry(entry_name.*)) |entry| {
                          const value = try extractEntryValue(entry, accessor.data);
                          const change = beam.make(.{ entry.name, value }, .{});
                          try changes.append(beam.allocator, change);
                      }
                  }

                  _ = try beam.send(accessor.pid, .{ .data_changed, changes.items }, .{});
              }

              // Update state for next iteration
              prev_state.* = state;
          }

          // Step 4: Drain output event queue and apply to domain buffers
          // This happens AFTER process (which updates inputs) and BEFORE queue (which sends outputs)
          {
              output_events_mutex.lock();
              defer output_events_mutex.unlock();

              for (output_events.items) |event| {
                  // Find matching domain
                  for (domain_accessors) |domain_accessor_resource| {
                      const accessor = domain_accessor_resource.unpack();
                      if (accessor.domain_ptr == event.domain_ptr) {
                          // Apply event to domain buffer
                          write_bits_to_domain(accessor.data, event.bit_offset, &event.data, event.bit_length);
                          break;
                      }
                  }
              }

              // Clear event queue after applying all events
              output_events.clearRetainingCapacity();
          }

          // Step 5: Check and notify master state changes
          master_state = try do_get_master_state(master);

          if (!std.meta.eql(prev_master_state, master_state)) {
              _ = try beam.send(master_pid, .{ .master_state_changed, master_state }, .{});
          }

          prev_master_state = master_state;

          // Step 6: Queue domain outputs at configured intervals (prepare outputs to send)
          for (domain_accessors) |domain_accessor_resource| {
              const accessor = domain_accessor_resource.unpack();
              if (counter % accessor.interval == 0) {
                  _ = ecrt.ecrt_domain_queue(accessor.getDomain());
              }
          }

          // Step 7: Send queued frames to network
          _ = ecrt.ecrt_master_send(master);

          // Step 8: Deterministic sleep to maintain exact cycle rate
          next_cycle_time += cycle_period_ns;
          const now = std.time.nanoTimestamp();
          const sleep_ns = next_cycle_time - now;

          if (sleep_ns > 0) {
              std.Thread.sleep(@intCast(sleep_ns));
          } else {
              // Cycle overrun: work took longer than the cycle period
              const overrun_us = @divTrunc(-sleep_ns, std.time.ns_per_us);
              std.debug.print("WARNING: Cycle overrun by {d}µs (cycle {d})\n", .{overrun_us, counter});
          }

          // Yield to BEAM scheduler periodically
          if (counter % yield_interval == 0) {
              try beam.yield();
          }

          counter +%= 1; // Wrapping increment
      }
  }
  """
end
