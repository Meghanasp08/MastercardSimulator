defmodule MastercardSimulator.MixProject do
  use Mix.Project

  def project do
    [
      app: :mastercard_simulator,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {MastercardSimulator.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug_crypto, "~> 2.0"}
    ]
  end
end
