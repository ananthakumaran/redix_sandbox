defmodule RedixSandbox.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ananthakumaran/redix_sandbox"

  def project do
    [
      app: :redix_sandbox,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Process-scoped Redis connections for concurrent ExUnit tests",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package(),
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
      {:nimble_ownership, "~> 0.3 or ~> 1.0"},
      {:redix, "~> 1.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "RedixSandbox",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
