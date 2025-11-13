defmodule EtherCAT.Config.Transformer do
  @moduledoc false
  # Spark transformer for validating EtherCAT configurations at compile time

  use Spark.Dsl.Transformer

  def transform(dsl_state) do
    # Validate domain references in entries
    domains = Spark.Dsl.Transformer.get_entities(dsl_state, [:hardware, :domains])
    slaves = Spark.Dsl.Transformer.get_entities(dsl_state, [:hardware, :slaves])

    domain_names = MapSet.new(domains, & &1.name)

    # Check all entry domain references
    invalid_refs =
      Enum.flat_map(slaves, fn slave ->
        Enum.reject(slave.entries, fn entry ->
          MapSet.member?(domain_names, entry.domain)
        end)
      end)

    if Enum.empty?(invalid_refs) do
      {:ok, dsl_state}
    else
      invalid_domains = Enum.map(invalid_refs, & &1.domain) |> Enum.uniq()

      {:error,
       Spark.Error.DslError.exception(
         module: __MODULE__,
         message: "Unknown domain references: #{inspect(invalid_domains)}",
         path: [:hardware, :slaves]
       )}
    end
  end
end
