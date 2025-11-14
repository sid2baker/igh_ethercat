defmodule EtherCAT.Config do
  @moduledoc """
  Declarative DSL for EtherCAT system configuration using Spark.

  ## Example

      defmodule MyMachine do
        use EtherCAT.Config

        domain :fast_loop, interval: 1
        domain :slow_loop, interval: 10

        slave position: 0, name: :temp_sensor do
          driver EtherCAT.Drivers.EL3202
          expect vendor: 0x00000002, product: 0x0C5A3052

          config do
            limit1 1000
            limit2 2000
            filter :enabled
          end

          entry :ch1, :value, domain: :fast_loop
          entry :ch1, :error, domain: :slow_loop
          entry :ch2, :value, domain: :fast_loop
        end

        slave position: 1, name: :valve_outputs do
          driver EtherCAT.Drivers.EL2008

          entry :ch1, :value, domain: :fast_loop
          entry :ch2, :value, domain: :fast_loop
        end
      end

      # Use the configuration
      {:ok, system} = EtherCAT.open(MyMachine)
      {:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
  """

  @doc """
  Builds a HardwareConfig struct from a Spark DSL module.
  """
  @spec build(module()) :: EtherCAT.Config.HardwareConfig.t()
  def build(module) do
    entities = Spark.Dsl.Extension.get_entities(module, [:hardware])

    master =
      entities
      |> Enum.find(&(&1.__struct__ == EtherCAT.Config.Dsl.Master))
      |> build_master()

    domains =
      entities
      |> Enum.filter(&(&1.__struct__ == EtherCAT.Config.Dsl.Domain))
      |> Enum.map(&build_domain/1)

    slaves =
      entities
      |> Enum.filter(&(&1.__struct__ == EtherCAT.Config.Dsl.Slave))
      |> Enum.map(&build_slave/1)

    %EtherCAT.Config.HardwareConfig{
      master: master,
      domains: domains,
      slaves: slaves
    }
  end

  defp build_master(nil), do: nil

  defp build_master(entity) do
    %EtherCAT.Config.MasterConfig{
      index: entity.index || 0,
      cycle_interval: entity.cycle_interval,
      nif_yield_interval: entity.nif_yield_interval || 100_000
    }
  end

  defp build_domain(entity) do
    %EtherCAT.Config.DomainConfig{
      name: entity.name,
      interval: entity.interval
    }
  end

  defp build_slave(entity) do
    entries =
      Enum.map(entity.entries, fn entry ->
        %EtherCAT.Config.EntryConfig{
          pdo_name: entry.pdo_name,
          entry_name: entry.entry_name,
          domain: entry.domain
        }
      end)

    # Extract driver module from driver entity
    driver =
      case entity.driver do
        nil -> nil
        driver_entity -> driver_entity.module
      end

    # Convert expect entity to expected map format
    expected =
      case entity.expect do
        nil -> nil
        expect -> %{vendor: expect.vendor, product: expect.product}
      end

    # Extract config fields if config entity exists
    config =
      case entity.config do
        nil -> %{}
        config -> config.__fields__ || %{}
      end

    %EtherCAT.Config.SlaveConfig{
      position: entity.position,
      name: entity.name,
      driver: driver,
      expected: expected,
      config: config,
      entries: entries
    }
  end

  @sections [
    %Spark.Dsl.Section{
      name: :hardware,
      top_level?: true,
      describe: "Hardware configuration for the EtherCAT system",
      entities: [
        %Spark.Dsl.Entity{
          name: :master,
          describe: "Configure the EtherCAT master",
          target: EtherCAT.Config.Dsl.Master,
          args: [],
          schema: [
            index: [
              type: :non_neg_integer,
              required: false,
              default: 0,
              doc: "EtherCAT master index (default: 0)"
            ],
            cycle_interval: [
              type: :pos_integer,
              required: true,
              doc: "PDO cyclic update interval in microseconds (e.g., 1_000 for 1ms)"
            ],
            nif_yield_interval: [
              type: :pos_integer,
              required: false,
              default: 100_000,
              doc: "NIF scheduler yielding interval in microseconds (default: 100_000)"
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :domain,
          describe: "Define a cyclic domain with update interval",
          target: EtherCAT.Config.Dsl.Domain,
          args: [:name],
          schema: [
            name: [
              type: :atom,
              required: true,
              doc: "Unique domain identifier"
            ],
            interval: [
              type: :pos_integer,
              required: true,
              doc: "Update interval in milliseconds"
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :slave,
          describe: "Define a slave device configuration",
          target: EtherCAT.Config.Dsl.Slave,
          args: [],
          schema: [
            position: [
              type: :non_neg_integer,
              required: true,
              doc: "Bus position (0-based)"
            ],
            name: [
              type: :atom,
              required: false,
              doc: "Semantic name for the slave"
            ]
          ],
          entities: [
            entries: [
              %Spark.Dsl.Entity{
                name: :entry,
                describe: "Route a PDO entry to a domain",
                target: EtherCAT.Config.Dsl.Entry,
                args: [:pdo_name, :entry_name],
                schema: [
                  pdo_name: [
                    type: :atom,
                    required: true,
                    doc: "PDO identifier (e.g., :ch1)"
                  ],
                  entry_name: [
                    type: :atom,
                    required: true,
                    doc: "Entry identifier (e.g., :value)"
                  ],
                  domain: [
                    type: :atom,
                    required: true,
                    doc: "Target domain name"
                  ]
                ]
              }
            ],
            driver: [
              %Spark.Dsl.Entity{
                name: :driver,
                describe: "Driver module for this slave",
                target: EtherCAT.Config.Dsl.Driver,
                args: [:module],
                schema: [
                  module: [
                    type: :atom,
                    required: true,
                    doc: "Driver module (e.g., EtherCAT.Drivers.EL3202)"
                  ]
                ]
              }
            ],
            config: [
              %Spark.Dsl.Entity{
                name: :config,
                describe: "Driver-specific configuration block",
                target: EtherCAT.Config.Dsl.Config,
                args: [],
                schema: [],
                recursive_as: :config
              }
            ],
            expect: [
              %Spark.Dsl.Entity{
                name: :expect,
                describe: "Expected vendor and product IDs for slave verification",
                target: EtherCAT.Config.Dsl.Expect,
                args: [],
                schema: [
                  vendor: [
                    type: :non_neg_integer,
                    required: true,
                    doc: "Expected vendor ID"
                  ],
                  product: [
                    type: :non_neg_integer,
                    required: true,
                    doc: "Expected product code"
                  ]
                ]
              }
            ]
          ],
          singleton_entity_keys: [:driver, :expect, :config]
        }
      ]
    }
  ]

  use Spark.Dsl.Extension,
    sections: @sections,
    transformers: [EtherCAT.Config.Transformer]

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl, default_extensions: [extensions: [EtherCAT.Config]]

      @doc """
      Returns the compiled hardware configuration.
      """
      def hardware_config do
        EtherCAT.Config.build(__MODULE__)
      end
    end
  end
end
