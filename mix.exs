defmodule RedixSandbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :redix_sandbox,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  @spec elixirc_paths(Mix.env()) :: [String.t()]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:nimble_ownership, "~> 1.0"},
      {:redix, "~> 1.1"}
    ]
  end
end
