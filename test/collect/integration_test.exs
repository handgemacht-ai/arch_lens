defmodule ArchLens.Collect.IntegrationTest do
  # async: false — resolves scopes and loads modules; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.{Externals, Runtime}
  alias ArchLens.CollectFixtures.PgRepo
  alias ArchLens.Edge
  alias ArchLens.Generator.{Document, Model, Scope}

  defp stripe_edge do
    %Edge{
      kind: :http_boundary,
      builder: {ArchLens.CollectFixtures.Custom, :stripe},
      target: "https://api.stripe.com",
      call_sites: [{"lib/custom.ex", 1}]
    }
  end

  defp scope do
    runtime = Runtime.collect(ecto_repos: [PgRepo], oban_config: [])
    externals = Externals.collect(deps: [:stripity_stripe], edges: [stripe_edge()])

    Scope.resolve(
      scanned_resources: [ArchLens.TestSupport.ValidPrivacyResource],
      edges: [stripe_edge()],
      oban_workers: [],
      runtime_components: runtime,
      external_systems: externals
    )
  end

  test "collected runtime + external elements serialise with source: collected" do
    json = scope() |> Model.to_json() |> Jason.decode!()

    assert json["runtime_components"] != []
    assert json["external_systems"] != []
    assert Enum.all?(json["runtime_components"], &(&1["source"] == "collected"))
    assert Enum.all?(json["external_systems"], &(&1["source"] == "collected"))

    stripe = Enum.find(json["external_systems"], &(&1["vendor"] == "Stripe"))
    assert stripe["id"] == "external:stripe"
    assert length(stripe["evidence"]) == 2
  end

  test "both seams render Markdown sections from the collected model" do
    md = scope() |> Model.to_map() |> Document.render()

    assert md =~ "## Runtime components"
    assert md =~ "ArchLens.CollectFixtures.PgRepo"
    assert md =~ "postgresql"
    assert md =~ "runner:Oban" or md =~ "`Oban`"

    assert md =~ "## External systems"
    assert md =~ "**Stripe**"
    assert md =~ "api.stripe.com"
  end

  test "the model is byte-identical across two runs from unchanged inputs" do
    scope = scope()
    assert Model.to_json(scope) == Model.to_json(scope)
  end
end
