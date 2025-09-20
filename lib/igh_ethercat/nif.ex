defmodule IghEthercat.Nif do
  @moduledoc false

  use Zig,
    otp_app: :igh_ethercat,
    c: [
      include_dirs: "/usr/include/",
      link_lib: {:system, "ethercat"}
    ],
    nifs: [
      version_magic: [],
      request_master: [],
      master_activate: [],
      master_receive: [],
      master_send: [],
      get_master_state: [],
      master_create_domain: [],
      master_slave_config: [],
      master_reset: [],
      release_master: [],
      master_get_slave: [],
      domain_process: [],
      domain_queue: [],
      domain_data: [],
      get_domain_value: [],
      set_domain_value: [],
      domain_state: [],
      slave_config_sync_manager: [],
      slave_config_pdo_assign_add: [],
      slave_config_pdo_assign_clear: [],
      slave_config_pdo_mapping_add: [],
      slave_config_pdo_mapping_clear: [],
      slave_config_reg_pdo_entry: [],
      master_get_sync_manager: [],
      master_get_pdo: [],
      master_get_pdo_entry: [],
      # maybe use dirty_cup/dirty_io
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

  pub const MasterResource = beam.Resource(*ecrt.ec_master_t, root, .{ .Callbacks = MasterResourceCallbacks });
  pub const DomainResource = beam.Resource(*ecrt.ec_domain_t, root, .{});
  pub const SlaveConfigResource = beam.Resource(*ecrt.ec_slave_config_t, root, .{});

  pub const MasterResourceCallbacks = struct {
      pub fn dtor(s: **ecrt.ec_master_t) void {
          std.debug.print("dtor called: {}\n", .{s.*});
          ecrt.ecrt_release_master(s.*);
      }
  };

  const MasterError = error{
      MasterNotFound,
      ResetError,
      GetSlaveError,
      SlaveConfigError,
      ActivateError,
      PdoRegError,
      InvalidDomainData,
  };

  // this is needed since zig doesn't support bitfields. See https://github.com/ziglang/zig/issues/1499
  const ec_master_state_t = packed struct {
      slaves_responding: u32,
      al_states: u4,
      link_up: u1,
      padding: u27, // 27 bits to align to 64 bits (8 bytes)
  };

  const ec_slave_config_state_t = packed struct {
      online: u1,
      operational: u1,
      al_state: u4,
      padding: u2, // 2 bits to align to 8 bits (1 byte)
  };

  pub fn version_magic() !u32 {
      return ecrt.ecrt_version_magic();
  }

  pub fn request_master(index: u32) !MasterResource {
      const master = ecrt.ecrt_request_master(index) orelse return MasterError.MasterNotFound;
      return MasterResource.create(master, .{ .released = false });
  }

  pub fn master_activate(master: MasterResource) !void {
      const result = ecrt.ecrt_master_activate(master.unpack());
      if (result != 0) return MasterError.ActivateError;
  }

  pub fn master_receive(master: MasterResource) !void {
      _ = ecrt.ecrt_master_receive(master.unpack());
  }

  pub fn master_send(master: MasterResource) !void {
      _ = ecrt.ecrt_master_send(master.unpack());
  }

  pub fn get_master_state(master: MasterResource) !beam.term {
      var state: ec_master_state_t = undefined;
      const result = ecrt.ecrt_master_state(master.unpack(), @ptrCast(&state));
      if (result != 0) {
          return MasterError.MasterNotFound;
      }
      return beam.make(state, .{ .as = .map });
  }

  pub fn master_create_domain(master: MasterResource) !DomainResource {
      const domain = ecrt.ecrt_master_create_domain(master.unpack()) orelse return MasterError.MasterNotFound;
      return DomainResource.create(domain, .{});
  }

  pub fn master_slave_config(master: MasterResource, alias: u16, position: u16, vendor_id: u32, product_code: u32) !SlaveConfigResource {
      const slave_config = ecrt.ecrt_master_slave_config(master.unpack(), alias, position, vendor_id, product_code) orelse return MasterError.SlaveConfigError;
      std.debug.print("Slave Config: {}\n", .{slave_config});
      std.debug.print("Master: {}\n", .{master.unpack()});
      return SlaveConfigResource.create(slave_config, .{});
  }

  pub fn master_get_slave(master: MasterResource, slave_position: u16) !beam.term {
      var slave_info: ecrt.ec_slave_info_t = undefined;
      const result = ecrt.ecrt_master_get_slave(master.unpack(), slave_position, &slave_info);
      if (result != 0) {
          return MasterError.GetSlaveError;
      }
      return beam.make(.{ .ok, slave_info }, .{});
  }

  pub fn master_reset(master: MasterResource) !void {
      const result = ecrt.ecrt_master_reset(master.unpack());
      if (result != 0) {
          return MasterError.ResetError;
      }
  }

  pub fn release_master(master: MasterResource) !void {
      // TODO check if master.release needs to be called
      ecrt.ecrt_release_master(master.unpack());
      master.release();
      std.debug.print("Master released: {}\n", .{master.unpack()});
  }

  pub fn domain_process(domain: DomainResource) !void {
      _ = ecrt.ecrt_domain_process(domain.unpack());
  }

  pub fn domain_queue(domain: DomainResource) !void {
      _ = ecrt.ecrt_domain_queue(domain.unpack());
  }

  // since ecrt_domain_data just returns domain->process_data
  // this should be managed inside zig.
  // So there should be these functions
  // get_domain_value(domain, offset, bit_position?)
  // which returns the current value
  // set_domain_value(domain, offset, bit_position?, value)
  // which sets the value
  // and subscribe_domain_value(domain, offset, bit_position?)
  // which subscribes to changes of the value
  pub fn domain_data(domain: DomainResource) ![*c]u8 {
      const result = ecrt.ecrt_domain_data(domain.unpack());
      return result;
  }

  // TODO add bit_position
  pub fn get_domain_value(domain: DomainResource, offset: u32) u8 {
      const data = ecrt.ecrt_domain_data(domain.unpack());
      std.debug.print("Byte 0: {}, Byte 1: {}\n", .{ data[0], data[1] });
      return data[offset];
  }

  // TODO handle bit precise offset
  pub fn set_domain_value(domain: DomainResource, offset: u32, value: []u8) !void {
      const target: [*]u8 = ecrt.ecrt_domain_data(domain.unpack());
      for (value, 0..) |byte, i| {
          target[i + offset] = byte;
      }
  }

  pub fn subscribe_domain_value(domain: DomainResource, offset: u32) !void {
      const data = ecrt.ecrt_domain_data(domain.unpack());
      _ = ecrt.ecrt_domain_subscribe(domain.unpack(), offset, data[offset]);
  }

  pub fn domain_state(domain: DomainResource) !beam.term {
      var state: ecrt.ec_domain_state_t = undefined;
      _ = ecrt.ecrt_domain_state(domain.unpack(), &state);
      return beam.make(state, .{});
  }

  pub fn slave_config_sync_manager(slave_config: SlaveConfigResource, sync_index: u8, direction: ecrt.ec_direction_t, watchdog_mode: ecrt.ec_watchdog_mode_t) !void {
      _ = ecrt.ecrt_slave_config_sync_manager(slave_config.unpack(), sync_index, direction, watchdog_mode);
  }

  pub fn slave_config_pdo_assign_add(slave_config: SlaveConfigResource, sync_index: u8, index: u16) !void {
      _ = ecrt.ecrt_slave_config_pdo_assign_add(slave_config.unpack(), sync_index, index);
  }

  pub fn slave_config_pdo_assign_clear(slave_config: SlaveConfigResource, sync_index: u8) !void {
      _ = ecrt.ecrt_slave_config_pdo_assign_clear(slave_config.unpack(), sync_index);
  }

  pub fn slave_config_pdo_mapping_add(slave_config: SlaveConfigResource, pdo_index: u16, entry_index: u16, entry_subindex: u8, entry_bit_length: u8) !void {
      _ = ecrt.ecrt_slave_config_pdo_mapping_add(slave_config.unpack(), pdo_index, entry_index, entry_subindex, entry_bit_length);
  }

  pub fn slave_config_pdo_mapping_clear(slave_config: SlaveConfigResource, pdo_index: u16) !void {
      _ = ecrt.ecrt_slave_config_pdo_mapping_clear(slave_config.unpack(), pdo_index);
  }

  pub fn slave_config_reg_pdo_entry(slave_config: SlaveConfigResource, entry_index: u16, entry_subindex: u8, domain: DomainResource) !u32 {
      var bit_position: c_uint = 0;
      const result: c_int = ecrt.ecrt_slave_config_reg_pdo_entry(slave_config.unpack(), entry_index, entry_subindex, domain.unpack(), &bit_position);
      if (bit_position != 0) {
          std.debug.print("Bit Position: {}\n", .{bit_position});
      }
      if (result >= 0) {
          return @as(u32, @intCast(result));
      } else {
          return MasterError.PdoRegError;
      }
  }

  pub fn master_get_sync_manager(master: MasterResource, slave_position: u16, sync_index: u8) !beam.term {
      var sync: ecrt.ec_sync_info_t = undefined;
      _ = ecrt.ecrt_master_get_sync_manager(master.unpack(), slave_position, sync_index, &sync);
      return beam.make(.{.index = sync.index, .dir = sync.dir, .n_pdos = sync.n_pdos, .watchdog_mode = sync.watchdog_mode}, .{});
  }

  pub fn master_get_pdo(master: MasterResource, slave_position: u16, sync_index: u8, pos: u16) !beam.term {
      var pdo: ecrt.ec_pdo_info_t = undefined;
      _ = ecrt.ecrt_master_get_pdo(master.unpack(), slave_position, sync_index, pos, &pdo);
      return beam.make(.{.index = pdo.index, .n_entries = pdo.n_entries}, .{});
  }

  pub fn master_get_pdo_entry(master: MasterResource, slave_position: u16, sync_index: u8, pdo_pos: u16, entry_pos: u16) !beam.term {
      var pdo_entry: ecrt.ec_pdo_entry_info_t = undefined;
      _ = ecrt.ecrt_master_get_pdo_entry(master.unpack(), slave_position, sync_index, pdo_pos, entry_pos, &pdo_entry);
      return beam.make(pdo_entry, .{});
  }

  pub fn cyclic_task(master_pid: beam.pid, master_resource: MasterResource, domain_pids: []beam.pid, domain_resources: []DomainResource, slave_pids: []beam.pid, slave_resources: []SlaveConfigResource) !void {
      if (domain_pids.len != domain_resources.len or slave_pids.len != slave_resources.len) {
          return error.MismatchedSliceLengths;
      }

      const master = master_resource.unpack();
      var master_state: ec_master_state_t = undefined;
      var prev_master_state: ec_master_state_t = undefined;

      var domains = std.ArrayList(struct {
          domain: *ecrt.ec_domain_t,
          state: ecrt.ec_domain_state_t,
          prev_data: []u8,
          data: []u8,
      }).init(beam.allocator);
      defer domains.deinit();

      for (domain_resources) |domain_resource| {
          const domain = domain_resource.unpack();
          const size = ecrt.ecrt_domain_size(domain);
          const data_ptr = ecrt.ecrt_domain_data(domain);
          if (data_ptr == null or size == 0) {
              return MasterError.InvalidDomainData;
          }
          // Memory is handled by ecrt.h
          const data = data_ptr[0..size];
          const prev_data: []u8 = beam.allocator.alloc(u8, size) catch return error.OutOfMemory;
          @memcpy(prev_data, data);

          try domains.append(.{ .domain = domain, .state = undefined, .prev_data = prev_data, .data = data });
      }

      var slaves = std.ArrayList(struct {
          slave: *ecrt.ec_slave_config_t,
          state: ec_slave_config_state_t,
      }).init(beam.allocator);
      defer slaves.deinit();

      for (slave_resources) |slave_resource| {
          try slaves.append(.{ .slave = slave_resource.unpack(), .state = undefined });
      }

      defer {
          beam.send(master_pid, .killed, .{}) catch {};
      }

      while (true) {
          _ = ecrt.ecrt_master_receive(master);

          _ = ecrt.ecrt_master_state(master, @ptrCast(&master_state));

          if (master_state.slaves_responding != prev_master_state.slaves_responding) {
              _ = try beam.send(master_pid, .{ .slaves_responding, master_state.slaves_responding }, .{});
          }
          if (master_state.al_states != prev_master_state.al_states) {
              _ = try beam.send(master_pid, .{ .al_states, master_state.al_states }, .{});
          }
          if (master_state.link_up != prev_master_state.link_up) {
              _ = try beam.send(master_pid, .{ .link_up, master_state.link_up }, .{});
          }
          prev_master_state = master_state;

          // Process all domains
          for (domains.items, 0..) |tuple, i| {
              const domain_pid = domain_pids[i];
              const domain = tuple.domain;
              const prev_state = tuple.state;
              var state: ecrt.ec_domain_state_t = undefined;
              const prev_data = tuple.prev_data;
              const data = tuple.data;

              _ = ecrt.ecrt_domain_process(domain);
              _ = ecrt.ecrt_domain_state(domain, &state);

              if (state.working_counter != prev_state.working_counter) {
                  _ = try beam.send(domain_pid, .{ .wc_changed, state.working_counter }, .{});
              }
              if (state.wc_state != prev_state.wc_state) {
                  _ = try beam.send(domain_pid, .{ .state_changed, state.wc_state }, .{});
              }

              if (!std.mem.eql(u8, data, prev_data)) {
                  _ = try beam.send(domain_pid, .{ .data_changed, data }, .{});
                  @memcpy(prev_data, data);
              }

              domains.items[i] = .{ .domain = domain, .state = state, .prev_data = prev_data, .data = data };

              _ = ecrt.ecrt_domain_queue(domain);
          }

          // Process all slaves
          for (slaves.items, 0..) |tuple, i| {
              const slave_pid = slave_pids[i];
              const slave = tuple.slave;
              const prev_state = tuple.state;
              var state: ec_slave_config_state_t = undefined;

              _ = ecrt.ecrt_slave_config_state(slave, @ptrCast(&state));

              if (state.al_state != prev_state.al_state) {
                  _ = try beam.send(slave_pid, .{ .state_changed, state.al_state }, .{});
              }
              if (state.online != prev_state.online) {
                  _ = try beam.send(slave_pid, .{ .online_changed, state.online }, .{});
              }
              if (state.operational != prev_state.operational) {
                  _ = try beam.send(slave_pid, .{ .operational_changed, state.operational }, .{});
              }

              slaves.items[i] = .{ .slave = slave, .state = state };
          }

          _ = ecrt.ecrt_master_send(master);
          try beam.yield();
          std.time.sleep(1_000_000_000);
      }
  }
  """
end
