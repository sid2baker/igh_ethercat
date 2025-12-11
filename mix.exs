defmodule EtherCAT.MixProject do
  use Mix.Project

  def project do
    [
      app: :ethercat,
      version: "0.1.0",
      elixir: "~> 1.19-rc",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zigler, path: "~/Development/git/zigler", runtime: false}
    ]
  end
end
