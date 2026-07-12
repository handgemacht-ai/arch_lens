defmodule TownArch.MixProject do
  @moduledoc """
  The town-level architecture map project. It owns no source of truth of its own:
  `mix arch_lens.town.map` reads the committed per-app `architecture.gen.json`
  artifacts named by `town-arch.manifest.json` and writes the combined
  `docs/town-architecture.gen.{md,json}`. Depends only on `arch_lens`, which
  provides the combiner and the mix task.
  """

  use Mix.Project

  def project do
    [
      app: :town_arch,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:arch_lens, path: ".."}]
  end
end
