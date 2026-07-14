defmodule ArchLens.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Architecture lens: privacy declarations and edge inventory for Ash-based rigs."
  @source_url "https://github.com/handgemacht-ai/arch_lens"

  def project do
    [
      app: :arch_lens,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      source_url: @source_url,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ArchLens.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :arch_lens,
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* docs),
      links: %{"GitHub" => @source_url}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:spark, "~> 2.7.2"},
      {:phoenix_pubsub, "~> 2.1"},
      # Oban stays optional: arch_lens must compile and test with it absent, so
      # any Oban-touching code is gated behind Code.ensure_loaded?/1.
      {:oban, "~> 2.18", optional: true},
      # Phoenix is test-only: the entry-point collector reads a host router via
      # Phoenix.Router.routes/1, but arch_lens must compile and run with Phoenix
      # absent (the collector guards on Code.ensure_loaded?/1 and calls through
      # apply/3). Tests build a minimal fixture router, which needs Phoenix present.
      {:phoenix, "~> 1.7", only: :test, runtime: false},
      # Boundary is test-only: the boundary-ingestion collector reads a host app's
      # declared boundary specs through the `boundary` lib's model, but arch_lens
      # must compile and run with boundary absent (the collector guards on
      # Code.ensure_loaded?/1). Tests define fixture boundaries, which need it
      # present.
      {:boundary, "~> 0.10", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
