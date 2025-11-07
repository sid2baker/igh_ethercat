defmodule EtherCAT.MixProject do
  use Mix.Project

  def project do
    [
      app: :ethercat,
      version: "0.1.0",
      elixir: "~> 1.19-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {EtherCAT.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zigler, "~> 0.15", runtime: false},
      {:telemetry, "~> 1.2"}
    ]
  end
end
