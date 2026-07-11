defmodule ArchLens.SystemIntegrationFixtures.Accounts.User do
  @moduledoc false
  def noop, do: :ok
end

defmodule ArchLens.SystemIntegrationFixtures.App do
  @moduledoc false
  use ArchLens.System

  architecture do
    actor(:developer, uses: [:browser, :api, :mcp], does: "captures annotations")
    external(:stripe, via: :http, target: "https://api.stripe.com", does: "billing")
    external(:otel, via: :otlp, target: "http://collector:4317", does: "traces")

    context(:accounts,
      does: "users and workspaces",
      modules: "ArchLens.SystemIntegrationFixtures.Accounts"
    )
  end
end

defmodule ArchLens.System.DeclaredIntegrationTest do
  # async: false — resolves scopes and loads modules; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Externals
  alias ArchLens.Generator.{Document, Model, Scope}
  alias ArchLens.System.{Declared, ValidationError}
  alias ArchLens.SystemIntegrationFixtures.App

  @collected [
    entry_points: [
      %{kind: :api, label: "GET /api"},
      %{kind: :mcp, label: "MCP"},
      %{kind: :browser, label: "widget"}
    ],
    # Real Collect.Externals output: an id/vendor + evidence element, no :target key.
    external_systems: Externals.collect(deps: [:stripity_stripe]),
    known_modules: ["ArchLens.SystemIntegrationFixtures.Accounts.User"]
  ]

  defp scope_opts(extra \\ []) do
    [domains: [], scanned_resources: [], edges: [], oban_workers: [], system: App]
    |> Keyword.merge(@collected)
    |> Keyword.merge(extra)
  end

  describe "Declared.resolve!/2" do
    test "returns actors/externals/contexts tagged source: declared" do
      declared = Declared.resolve!(App, Map.new(@collected))

      assert Enum.all?(declared.actors, &(&1.source == "declared"))
      assert Enum.all?(declared.externals, &(&1.source == "declared"))
      assert Enum.all?(declared.contexts, &(&1.source == "declared"))
      assert declared.warnings == []
    end

    test "records skipped-validation warnings when nothing was collected" do
      declared = Declared.resolve!(App, %{})

      assert declared.warnings != []
      assert Enum.any?(declared.warnings, &(&1 =~ "entry points not collected"))
      assert Enum.any?(declared.warnings, &(&1 =~ "external systems not collected"))
      assert Enum.any?(declared.warnings, &(&1 =~ "module list unavailable"))
    end

    test "raises with every failing check when declarations do not match" do
      inputs = %{
        entry_points: [%{kind: :api}],
        external_systems: Externals.collect(deps: [:sentry]),
        known_modules: ["Some.Other.Module"]
      }

      error = assert_raise ValidationError, fn -> Declared.resolve!(App, inputs) end
      message = Exception.message(error)

      assert message =~ "external :stripe"
      assert message =~ "context :accounts"
    end
  end

  describe "Scope.resolve/1 with :system" do
    test "populates declared_architecture with the validated value" do
      scope = Scope.resolve(scope_opts())

      assert %{actors: [_ | _], contexts: [_ | _], warnings: []} = scope.declared_architecture
    end

    test "raises when the declared architecture is invalid" do
      assert_raise ValidationError, fn ->
        Scope.resolve(scope_opts(external_systems: Externals.collect(deps: [:sentry])))
      end
    end
  end

  describe "Document + Model rendering" do
    test "renders distinct Actors and Contexts sections" do
      md = App |> render_scope() |> elem(0)

      assert md =~ "## Actors"
      assert md =~ "- **developer** — captures annotations (uses: browser, api, mcp)"
      assert md =~ "## Contexts"
      # A central `context` declaration now renders with its origin, not `(modules:)`.
      assert md =~ "- **accounts** — users and workspaces _(central declaration, deprecated)_"
    end

    test "declared_architecture JSON is an object of actors/contexts/warnings" do
      {_md, json} = render_scope(App)

      declared = json["declared_architecture"]
      assert is_map(declared)
      assert Enum.map(declared["actors"], & &1["name"]) == ["developer"]
      assert Enum.map(declared["contexts"], & &1["name"]) == ["accounts"]
      assert declared["warnings"] == []
      # externals are NOT under declared_architecture — they merge into external_systems.
      refute Map.has_key?(declared, "externals")
    end

    test "skipped-validation warnings surface in both artifacts" do
      opts = scope_opts(entry_points: [], external_systems: [], known_modules: [])
      # external_systems empty + no collected → externals become declared-only, no error.
      model = opts |> Scope.resolve() |> Model.to_map()

      md = Document.render(model)
      json = model |> Model.encode() |> Jason.decode!()

      assert md =~ "> validation skipped:"
      assert json["declared_architecture"]["warnings"] != []
    end
  end

  describe "declared externals merge with collected external systems" do
    test "a matched HTTP external collapses into one element with both evidences" do
      {_md, json} = render_scope(App)

      stripe = Enum.find(json["external_systems"], &(&1["name"] == "stripe"))
      assert stripe["provenance"] == ["collected", "declared"]
      assert stripe["source"] == "collected"
      assert stripe["target"] == "https://api.stripe.com"
    end

    test "an unmatched non-HTTP external stays declared-only" do
      {_md, json} = render_scope(App)

      otel = Enum.find(json["external_systems"], &(&1["name"] == "otel"))
      assert otel["provenance"] == ["declared"]
      assert otel["source"] == "declared"
    end

    test "both externals render in the External systems section" do
      {md, _json} = render_scope(App)

      assert md =~ "## External systems"
      assert md =~ "stripe → https://api.stripe.com (http)"
      assert md =~ "otel → http://collector:4317 (otlp)"
    end

    test "generating twice is byte-identical" do
      json_once = scope_opts() |> Scope.resolve() |> Model.to_json()
      json_twice = scope_opts() |> Scope.resolve() |> Model.to_json()
      assert json_once == json_twice
    end
  end

  defp render_scope(system) do
    model = [system: system] |> scope_opts() |> Scope.resolve() |> Model.to_map()
    {Document.render(model), model |> Model.encode() |> Jason.decode!()}
  end
end
