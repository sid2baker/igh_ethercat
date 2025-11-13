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
    domains = Spark.Dsl.Extension.get_entities(module, [:hardware, :domains])
    slaves = Spark.Dsl.Extension.get_entities(module, [:hardware, :slaves])

    %EtherCAT.Config.HardwareConfig{
      domains: Enum.map(domains, &build_domain/1),
      slaves: Enum.map(slaves, &build_slave/1)
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

    %EtherCAT.Config.SlaveConfig{
      position: entity.position,
      name: entity.name,
      driver: entity.driver,
      expected: entity.expected,
      config: entity.config || %{},
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
            config: [
              %Spark.Dsl.Entity{
                name: :config,
                describe: "Driver-specific configuration block",
                target: EtherCAT.Config.Dsl.Config,
                args: [],
                schema: [],
                recursive_as: :config
              }
            ]
          ],
          singleton_entity_keys: [:driver, :expected]
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
