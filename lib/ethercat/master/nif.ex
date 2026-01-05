defmodule EtherCAT.Master.Nif do
  @test? Mix.env() == :test
  @nerves_sysroot System.get_env("NERVES_SDK_SYSROOT")

  @default_include_dir if @nerves_sysroot,
                         do: Path.join(@nerves_sysroot, "usr/include"),
                         else: "/usr/local/include"

  @default_lib_dir if @nerves_sysroot,
                     do: Path.join(@nerves_sysroot, "usr/lib"),
                     else: "/usr/local/lib64"

  @igh_include_dir Application.compile_env(:ethercat, :igh_include_dir, @default_include_dir)
  @igh_lib_dir Application.compile_env(:ethercat, :igh_lib_dir, @default_lib_dir)

  @link_lib (if @test? do
               [{:system, "fakeethercat"}, {:system, "ethercat"}]
             else
               {:system, "ethercat"}
             end)

  use Zig,
    otp_app: :ethercat,
    zig_code_path: "main.zig",
    c: [
      include_dirs: [@igh_include_dir],
      library_dirs: [@igh_lib_dir],
      link_lib: @link_lib
    ],
    nifs: [
      version: [],
      create_master: [],
      destroy_master: [],
      reset_master: [],
      set_cyclic_interval: [],
      get_master_info: [],
      create_domain: [],
      get_slave_info: [],
      create_slave: [],
      slave_config_sdo: [],
      slave_config_sync_manager: [],
      slave_config_pdo_assign_add: [],
      slave_config_pdo_assign_clear: [],
      slave_config_pdo_mapping_add: [],
      slave_config_pdo_mapping_clear: [],
      register_pdo_entry: [],
      read_pdo_value: [],
      write_pdo_value: [],
      enable_thread: [],
      stop_thread: [],
      create_watch_hardware_thread: [:threaded],
      create_cyclic_thread: [:threaded]
    ],
    resources: [
      :MasterResource,
      :DomainResource,
      :SlaveResource
    ]
end
