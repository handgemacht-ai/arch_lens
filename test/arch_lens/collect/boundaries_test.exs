defmodule ArchLens.Collect.BoundariesTest do
  # async: false — loads modules and resolves scopes; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.BoundaryFixtures, as: BF
  alias ArchLens.Collect.Boundaries
  alias ArchLens.Generator.{Architecture, Document, Model, Scope}
  alias ArchLens.Generator.Sections.Boundaries, as: Section

  @engine BF.Engine
  @toolbox BF.Toolbox
  @plain BF.PlainModule
  @container BF.Engine.Container
  @enums BF.Engine.Enums

  @modules [@engine, @toolbox, @plain]

  @valid_classifications %{
    @engine => [
      sanctioned: [{@container, "run & container artifacts sub-API"}],
      grandfathered: [@enums]
    ]
  }

  defp scan(opts \\ []), do: Boundaries.scan([boundary_modules: @modules] ++ opts)
  defp by_id(result), do: Map.new(result.boundaries, &{&1.id, &1})

  defp engine(result),
    do: Map.fetch!(by_id(result), "boundary:#{Atom.to_string(@engine) |> strip()}")

  defp strip("Elixir." <> rest), do: rest
  defp strip(other), do: other

  describe "scan/1 — discovery and element shape" do
    test "keeps only modules that declare a boundary, dropping plain modules" do
      ids = scan() |> Map.fetch!(:boundaries) |> Enum.map(& &1.id)

      assert ids == [
               "boundary:ArchLens.BoundaryFixtures.Engine",
               "boundary:ArchLens.BoundaryFixtures.Toolbox"
             ]
    end

    test "every boundary is source: collected with a stable boundary:<Name> id and front door" do
      for boundary <- scan().boundaries do
        assert boundary.source == :collected
        assert String.starts_with?(boundary.id, "boundary:")
        assert boundary.front_door == boundary.name
      end
    end

    test "a strict boundary carries its type and both checks on by default" do
      engine = engine(scan())

      assert engine.name == "ArchLens.BoundaryFixtures.Engine"
      assert engine.type == "strict"
      assert engine.check == %{in: true, out: true}
    end

    test "a relaxed boundary carries its verbatim deps (with mode) and a disabled check" do
      toolbox = Map.fetch!(by_id(scan()), "boundary:ArchLens.BoundaryFixtures.Toolbox")

      assert toolbox.type == "relaxed"
      assert toolbox.check == %{in: true, out: false}
      assert toolbox.deps == [%{module: "ArchLens.BoundaryFixtures.Engine", mode: "runtime"}]
    end

    test "boundaries are de-duplicated and sorted by id" do
      ids =
        [boundary_modules: [@toolbox, @engine, @engine]]
        |> Boundaries.scan()
        |> Map.fetch!(:boundaries)
        |> Enum.map(& &1.id)

      assert ids == [
               "boundary:ArchLens.BoundaryFixtures.Engine",
               "boundary:ArchLens.BoundaryFixtures.Toolbox"
             ]
    end
  end

  describe "scan/1 — export classification (structured, never inferred)" do
    test "each export lands in its declared group; reasons are carried verbatim" do
      exports = engine(scan(classifications: @valid_classifications)).exports

      assert exports.sanctioned == [
               %{
                 module: "ArchLens.BoundaryFixtures.Engine.Container",
                 reason: "run & container artifacts sub-API"
               }
             ]

      assert exports.grandfathered == ["ArchLens.BoundaryFixtures.Engine.Enums"]
      assert exports.unclassified == ["ArchLens.BoundaryFixtures.Engine.Secret"]
    end

    test "with no classification every export is reported honestly as unclassified" do
      exports = engine(scan()).exports

      assert exports.sanctioned == []
      assert exports.grandfathered == []

      assert exports.unclassified == [
               "ArchLens.BoundaryFixtures.Engine.Container",
               "ArchLens.BoundaryFixtures.Engine.Enums",
               "ArchLens.BoundaryFixtures.Engine.Secret"
             ]
    end

    test "valid classifications produce no errors" do
      assert scan(classifications: @valid_classifications).errors == []
    end
  end

  describe "scan/1 — classification validation (loud errors)" do
    test "classifying a module that is not a boundary is an unknown_boundary error" do
      errors = scan(classifications: %{@plain => [sanctioned: [{@container, "x"}]]}).errors

      assert errors == [{:unknown_boundary, "ArchLens.BoundaryFixtures.PlainModule"}]
    end

    test "classifying a module the boundary does not export is an unknown_export error" do
      errors = scan(classifications: %{@engine => [grandfathered: [BF.Engine.Nope]]}).errors

      assert errors == [
               {:unknown_export, "ArchLens.BoundaryFixtures.Engine",
                "ArchLens.BoundaryFixtures.Engine.Nope"}
             ]
    end

    test "a sanctioned export without a reason is a missing_reason error" do
      errors = scan(classifications: %{@engine => [sanctioned: [{@container, "  "}]]}).errors

      assert errors == [
               {:missing_reason, "ArchLens.BoundaryFixtures.Engine",
                "ArchLens.BoundaryFixtures.Engine.Container"}
             ]
    end

    test "a module classified both ways is a conflicting error" do
      errors =
        scan(
          classifications: %{
            @engine => [sanctioned: [{@container, "keep"}], grandfathered: [@container]]
          }
        ).errors

      assert {:conflicting, "ArchLens.BoundaryFixtures.Engine",
              "ArchLens.BoundaryFixtures.Engine.Container"} in errors
    end
  end

  describe "scan/1 — escape hatches and lib-only discovery" do
    test "enabled: false skips ingestion entirely" do
      assert Boundaries.scan(boundary_modules: @modules, enabled: false) ==
               %{boundaries: [], errors: []}
    end

    test "no :app and no :boundary_modules yields an empty result" do
      assert Boundaries.scan([]) == %{boundaries: [], errors: []}
    end

    test "the lib-only app scan excludes test/support boundaries" do
      # The boundary fixtures live under test/support and use `boundary`, yet the
      # lib-only scan of :arch_lens (which declares no lib/ boundaries) must not
      # surface them — the same guarantee the tasks scan makes.
      assert Boundaries.scan(app: :arch_lens) == %{boundaries: [], errors: []}
    end
  end

  describe "Scope / Model / Document integration" do
    defp resolve(extra) do
      Scope.resolve([domains: [], scanned_resources: [], edges: [], oban_workers: []] ++ extra)
    end

    defp boundary_scope,
      do:
        resolve(
          boundary_modules: @modules,
          boundary_classifications: @valid_classifications
        )

    test "the JSON model carries the boundaries and stays schema_version 3" do
      json = boundary_scope() |> Model.to_json() |> Jason.decode!()

      assert json["schema_version"] == 3

      engine =
        Enum.find(json["boundaries"], &(&1["id"] == "boundary:ArchLens.BoundaryFixtures.Engine"))

      assert engine["front_door"] == "ArchLens.BoundaryFixtures.Engine"
      assert engine["type"] == "strict"
      assert engine["source"] == "collected"

      assert engine["exports"]["sanctioned"] == [
               %{
                 "module" => "ArchLens.BoundaryFixtures.Engine.Container",
                 "reason" => "run & container artifacts sub-API"
               }
             ]
    end

    test "the boundaries key is absent when the app declares no boundaries" do
      model = resolve([]) |> Model.to_map()

      refute Map.has_key?(model, :boundaries)
      refute Document.render(model) =~ "## Boundaries"
    end

    test "Markdown renders the section, the classification groups, deps, and disabled checks" do
      md = boundary_scope() |> Model.to_map() |> Document.render()

      assert md =~ "## Boundaries"
      assert md =~ "### ArchLens.BoundaryFixtures.Engine (strict)"
      assert md =~ "- Front door: `ArchLens.BoundaryFixtures.Engine`"

      assert md =~
               "  - `ArchLens.BoundaryFixtures.Engine.Container` — run & container artifacts sub-API"

      assert md =~ "- Grandfathered exports: `ArchLens.BoundaryFixtures.Engine.Enums`"
      assert md =~ "- Unclassified exports: `ArchLens.BoundaryFixtures.Engine.Secret`"
      assert md =~ "### ArchLens.BoundaryFixtures.Toolbox (relaxed)"
      assert md =~ "- Deps: `ArchLens.BoundaryFixtures.Engine` (runtime)"
      assert md =~ "- Checks disabled: outbound"
    end

    test "the folded boundaries inventory is byte-identical across resolves" do
      assert Model.to_json(boundary_scope()) == Model.to_json(boundary_scope())
    end
  end

  describe "render_artifacts — boundaries gate" do
    defp gate_opts(classifications),
      do: [
        scanned_resources: [],
        edges: [],
        oban_workers: [],
        domains: [],
        boundary_modules: @modules,
        boundary_classifications: classifications
      ]

    test "valid classifications pass the gate and render the section" do
      assert {:ok, md} = Architecture.render(gate_opts(@valid_classifications))
      assert md =~ "## Boundaries"
    end

    test "an invalid classification fails generation, naming the offender" do
      opts = gate_opts(%{@engine => [sanctioned: [{BF.Engine.Missing, "x"}]]})

      assert {:error, {:invalid_boundaries, errors}} = Architecture.render(opts)

      assert {:unknown_export, "ArchLens.BoundaryFixtures.Engine",
              "ArchLens.BoundaryFixtures.Engine.Missing"} in errors
    end

    test "the error message names the boundary, the export, and the escape hatch" do
      message =
        Architecture.format_error(
          {:invalid_boundaries, [{:missing_reason, "MyApp.Engine", "MyApp.Engine.Container"}]}
        )

      assert message =~ "MyApp.Engine sanctions MyApp.Engine.Container without a reason"
      assert message =~ "config :arch_lens, :boundaries, false"
    end
  end

  describe "Diff — boundaries participate as a diffable group" do
    test "a boundary added over a pre-boundaries baseline diffs cleanly (same schema)" do
      baseline = resolve([]) |> Model.to_map()
      candidate = boundary_scope() |> Model.to_map()

      result = ArchLens.Diff.compute(baseline, candidate)

      added = Enum.filter(result.added, &(&1.group == "boundaries"))

      assert Enum.map(added, &{&1.kind, &1.id}) == [
               {"boundary", "boundary:ArchLens.BoundaryFixtures.Engine"},
               {"boundary", "boundary:ArchLens.BoundaryFixtures.Toolbox"}
             ]

      # Additive structural info, not a data/privacy widening.
      assert Enum.all?(added, &(&1.severity == :info))
    end
  end

  describe "Sections.Boundaries.render/1 — dirty cross-references" do
    test "a boundary with dirty xrefs renders them (hand-built jsonable entry)" do
      entry = %{
        "id" => "boundary:MyApp.Engine",
        "name" => "MyApp.Engine",
        "type" => "strict",
        "front_door" => "MyApp.Engine",
        "check" => %{"in" => true, "out" => true},
        "deps" => [],
        "dirty_xrefs" => ["MyApp.Leak"],
        "exports" => %{"sanctioned" => [], "grandfathered" => [], "unclassified" => []}
      }

      md = Section.render([entry]) |> Enum.join("\n")

      assert md =~ "- Dirty cross-references: `MyApp.Leak`"
    end

    test "render/1 yields nothing for an empty or nil section" do
      assert Section.render([]) == []
      assert Section.render(nil) == []
    end
  end
end
