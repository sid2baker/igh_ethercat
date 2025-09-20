defmodule IghEthercat.MixProject do
  use Mix.Project

  def project do
    [
      app: :igh_ethercat,
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
      mod: {IghEthercat.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zigler, github: "E-xyza/zigler", runtime: false}
    ]
  end
end
