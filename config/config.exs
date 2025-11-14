import Config

# Configure Spark formatter for EtherCAT.Config DSL
config :spark, :formatter,
  remove_parens?: true,
  "EtherCAT.Config": [
    section_order: [
      # Domains should be defined before slaves that use them
      :domain,
      :slave
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
