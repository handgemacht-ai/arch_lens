defmodule ArchLens.Town.CombineTest do
  use ExUnit.Case, async: true

  alias ArchLens.Generator.Model
  alias ArchLens.Town
  alias ArchLens.Town.Manifest
  alias Mix.Tasks.ArchLens.Town.Map, as: Task

  # A minimal, schema-v3 per-app artifact model. `opts` override the app block and
  # any section list; unspecified sections default to empty so a scenario only states
  # what it exercises.
  defp model(opts) do
    app =
      %{"id" => opts[:id], "source" => "collected"}
      |> put_present("name", opts[:name])
      |> put_present("aliases", opts[:aliases])

    %{
      "schema_version" => Keyword.get(opts, :schema_version, 3),
      "app" => app,
      "resources" => opts[:resources] || [],
      "oban_workers" => opts[:oban_workers] || [],
      "entry_points" => opts[:entry_points] || [],
      "external_systems" => opts[:external_systems] || [],
      "declared_architecture" => Keyword.get(opts, :declared_architecture, [])
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp input(path, model), do: %{path: path, model: model}

  # The grounded bridge: claude-code-course reaches havi through a collected HTTP
  # boundary whose evidence value carries the symbolic `havi:` scheme; havi answers
  # to the `havi` alias.
  defp havi_boundary_external do
    %{
      "id" => "external:havi",
      "vendor" => "havi",
      "source" => "collected",
      "provenance" => ["collected"],
      "evidence" => [%{"type" => "http_boundary", "value" => "havi:/api/annotations"}]
    }
  end

  defp havi_model(extra \\ []) do
    model(
      Keyword.merge(
        [
          id: "havi",
          name: "HAVI",
          aliases: ["havi", "havi.handgemacht.ai"],
          entry_points: [
            %{
              "kind" => "api",
              "method" => "GET",
              "path" => "/api/annotations",
              "handler" => "HaviWeb.AnnotationController"
            }
          ]
        ],
        extra
      )
    )
  end

  describe "combine/1 links" do
    test "resolves the grounded caller→target boundary and enriches the exact endpoint" do
      inputs = [
        input("havi.json", havi_model()),
        input(
          "ccc.json",
          model(id: "claude_code_course", external_systems: [havi_boundary_external()])
        )
      ]

      assert {:ok, town} = Town.combine(inputs)
      assert [link] = town.links

      assert link.id == "link:claude_code_course=>havi:external:havi"
      assert link.from == "claude_code_course"
      assert link.to == "havi"
      assert link.kind == "http"
      assert link.basis == "collected_boundary"
      assert link.provenance == ["collected"]
      assert link.matched_on == "havi"

      assert link.to_endpoint == %{
               method: "GET",
               path: "/api/annotations",
               handler: "HaviWeb.AnnotationController",
               kind: "api"
             }
    end

    test "carries a declared external's does verbatim and never synthesises one" do
      declared = %{
        "id" => "external:reports",
        "name" => "Reports",
        "via" => "req",
        "target" => "reports:/v1/export",
        "does" => "Exports monthly billing reports.",
        "source" => "declared",
        "provenance" => ["declared"]
      }

      reports =
        model(
          id: "reports",
          entry_points: [
            %{
              "kind" => "api",
              "method" => "GET",
              "path" => "/v1/export",
              "handler" => "ReportsWeb.ExportController"
            }
          ]
        )

      inputs = [
        input("reports.json", reports),
        input("billing.json", model(id: "billing", external_systems: [declared]))
      ]

      assert {:ok, town} = Town.combine(inputs)
      assert [link] = town.links
      assert link.kind == "http"
      assert link.basis == "declared_external"
      assert link.does == "Exports monthly billing reports."
      assert link.matched_on == "reports"
    end

    test "a collected-only external carries no does (nothing is invented)" do
      inputs = [
        input("havi.json", havi_model()),
        input("ccc.json", model(id: "ccc", external_systems: [havi_boundary_external()]))
      ]

      assert {:ok, %{links: [link]}} = Town.combine(inputs)
      refute Map.has_key?(link, :does)
    end

    test "matches a declared real hostname, not only a symbolic scheme" do
      external = %{
        "id" => "external:havi",
        "vendor" => "havi.handgemacht.ai",
        "source" => "collected",
        "provenance" => ["collected"],
        "evidence" => [
          %{"type" => "http_boundary", "value" => "https://havi.handgemacht.ai/api/annotations"}
        ]
      }

      inputs = [
        input("havi.json", havi_model()),
        input("peer.json", model(id: "peer", external_systems: [external]))
      ]

      assert {:ok, %{links: [link]}} = Town.combine(inputs)
      assert link.matched_on == "havi.handgemacht.ai"
      assert link.to_endpoint.path == "/api/annotations"
    end

    test "picks the deterministically-first entry point when several share the path" do
      havi =
        havi_model(
          entry_points: [
            %{
              "kind" => "api",
              "method" => "POST",
              "path" => "/api/annotations",
              "handler" => "HaviWeb.AnnotationController"
            },
            %{
              "kind" => "api",
              "method" => "GET",
              "path" => "/api/annotations",
              "handler" => "HaviWeb.AnnotationController"
            }
          ]
        )

      inputs = [
        input("havi.json", havi),
        input("ccc.json", model(id: "ccc", external_systems: [havi_boundary_external()]))
      ]

      assert {:ok, %{links: [link]}} = Town.combine(inputs)
      assert link.to_endpoint.method == "GET"
    end

    test "omits to_endpoint when the target has no exact-path entry point" do
      inputs = [
        input("havi.json", havi_model(entry_points: [])),
        input("ccc.json", model(id: "ccc", external_systems: [havi_boundary_external()]))
      ]

      assert {:ok, %{links: [link]}} = Town.combine(inputs)
      refute Map.has_key?(link, :to_endpoint)
    end

    test "never links an external to its own app" do
      self_ref = %{
        "id" => "external:havi",
        "vendor" => "havi",
        "provenance" => ["collected"],
        "evidence" => [%{"type" => "http_boundary", "value" => "havi:/api/annotations"}]
      }

      inputs = [input("havi.json", havi_model(external_systems: [self_ref]))]

      assert {:ok, %{links: links}} = Town.combine(inputs)
      assert links == []
    end
  end

  describe "combine/1 unresolved externals" do
    test "surfaces every unmatched external, sorted by app then id" do
      havi =
        havi_model(
          external_systems: [
            %{
              "id" => "external:stripe",
              "vendor" => "Stripe",
              "provenance" => ["collected"],
              "evidence" => [%{"type" => "dep", "value" => "stripity_stripe"}]
            }
          ]
        )

      ccc =
        model(
          id: "ccc",
          external_systems: [
            havi_boundary_external(),
            %{"id" => "external:sentry", "vendor" => "Sentry", "provenance" => ["collected"]}
          ]
        )

      assert {:ok, town} = Town.combine([input("havi.json", havi), input("ccc.json", ccc)])

      assert Enum.map(town.unresolved_externals, &{&1.app, &1.external_id}) == [
               {"ccc", "external:sentry"},
               {"havi", "external:stripe"}
             ]

      refute Enum.any?(town.unresolved_externals, &(&1.external_id == "external:havi"))
      stripe = Enum.find(town.unresolved_externals, &(&1.external_id == "external:stripe"))
      assert stripe.vendor == "Stripe"
      assert stripe.evidence == [%{"type" => "dep", "value" => "stripity_stripe"}]
    end
  end

  describe "combine/1 apps + counts" do
    test "counts each section, treating a list-shaped declared_architecture as zero contexts" do
      havi =
        havi_model(
          resources: [%{"id" => "res:A"}, %{"id" => "res:B"}],
          oban_workers: [%{"id" => "oban:W"}],
          declared_architecture: %{
            "actors" => [%{"name" => "User"}],
            "contexts" => [%{"name" => "accounts"}, %{"name" => "annotations"}],
            "warnings" => []
          }
        )

      ccc = model(id: "ccc", declared_architecture: [])

      assert {:ok, town} = Town.combine([input("havi.json", havi), input("ccc.json", ccc)])
      assert Enum.map(town.apps, & &1.id) == ["ccc", "havi"]

      havi_app = Enum.find(town.apps, &(&1.id == "havi"))
      assert havi_app.name == "HAVI"
      assert havi_app.aliases == ["havi", "havi.handgemacht.ai"]
      assert havi_app.source_schema_version == 3

      assert havi_app.counts == %{
               contexts: 2,
               actors: 1,
               resources: 2,
               oban_workers: 1,
               entry_points: 1,
               external_systems: 0
             }

      ccc_app = Enum.find(town.apps, &(&1.id == "ccc"))
      assert ccc_app.counts.contexts == 0
      refute Map.has_key?(ccc_app, :name)
    end

    test "the town map carries its own schema_version 1 and kind town_map" do
      assert {:ok, town} = Town.combine([input("havi.json", havi_model())])
      assert town.schema_version == 1
      assert town.kind == "town_map"
      assert Town.schema_version() == 1
    end
  end

  describe "combine/1 determinism" do
    test "encodes byte-identically regardless of input order" do
      havi = havi_model()
      ccc = model(id: "ccc", external_systems: [havi_boundary_external()])

      {:ok, forward} = Town.combine([input("havi.json", havi), input("ccc.json", ccc)])
      {:ok, reversed} = Town.combine([input("ccc.json", ccc), input("havi.json", havi)])

      assert Model.encode(forward) == Model.encode(reversed)
      assert Model.encode(forward) == Model.encode(forward)
      assert String.ends_with?(Model.encode(forward), "\n")
    end
  end

  describe "combine/1 gates" do
    test "raises SchemaMismatchError naming the file and version on a non-v3 input" do
      inputs = [
        input("havi.json", havi_model()),
        input("stale.json", model(id: "old", schema_version: 2))
      ]

      error =
        assert_raise Town.SchemaMismatchError, fn -> Town.combine(inputs) end

      message = Exception.message(error)
      assert message =~ "stale.json"
      assert message =~ "schema_version 2"
      assert message =~ "schema_version 3"
    end

    test "returns a duplicate-identity error naming both files" do
      inputs = [
        input("a/architecture.gen.json", model(id: "havi")),
        input("b/architecture.gen.json", model(id: "havi"))
      ]

      assert {:error, {:duplicate_identity, "havi", paths}} = Town.combine(inputs)
      assert paths == ["a/architecture.gen.json", "b/architecture.gen.json"]
    end
  end

  describe "Manifest.load/1 and the mix task" do
    setup do
      dir = Path.join(System.tmp_dir!(), "arch_lens_town_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "havi/docs"))
      File.mkdir_p!(Path.join(dir, "ccc/docs"))
      File.mkdir_p!(Path.join(dir, "town/docs"))
      on_exit(fn -> File.rm_rf(dir) end)

      write_artifact(dir, "havi/docs/architecture.gen.json", havi_model())

      write_artifact(
        dir,
        "ccc/docs/architecture.gen.json",
        model(id: "claude_code_course", external_systems: [havi_boundary_external()])
      )

      manifest_path = Path.join(dir, "town/town-arch.manifest.json")

      File.write!(
        manifest_path,
        Jason.encode!(%{
          "apps" => [
            %{"artifact" => "../havi/docs/architecture.gen.json"},
            %{"artifact" => "../ccc/docs/architecture.gen.json"}
          ],
          "output" => "docs/town-architecture.gen.md"
        })
      )

      %{
        dir: dir,
        manifest: manifest_path,
        md: Path.join(dir, "town/docs/town-architecture.gen.md"),
        json: Path.join(dir, "town/docs/town-architecture.gen.json")
      }
    end

    test "load/1 resolves inputs and output relative to the manifest", ctx do
      assert {:ok, loaded} = Manifest.load(ctx.manifest)
      assert Enum.map(loaded.inputs, & &1.model["app"]["id"]) == ["havi", "claude_code_course"]
      assert loaded.output_md == ctx.md
      assert loaded.output_json == ctx.json
    end

    test "load/1 fails and names a missing input artifact", ctx do
      File.rm!(Path.join(ctx.dir, "ccc/docs/architecture.gen.json"))
      assert {:error, {:missing_input, path}} = Manifest.load(ctx.manifest)
      assert path =~ "ccc/docs/architecture.gen.json"
    end

    test "the task writes both artifacts and --check then passes", ctx do
      assert Task.emit(ctx.manifest, false) == :ok
      assert File.read!(ctx.md) =~ "# Town architecture"
      assert Jason.decode!(File.read!(ctx.json))["kind"] == "town_map"
      assert File.read!(ctx.md) =~ "claude_code_course** → **havi"

      assert Task.emit(ctx.manifest, true) == :ok
    end

    test "--check fails and names the stale JSON sidecar", ctx do
      assert Task.emit(ctx.manifest, false) == :ok
      File.write!(ctx.json, "{}\n")

      assert_raise Mix.Error, ~r/#{Regex.escape(ctx.json)}/, fn ->
        Task.emit(ctx.manifest, true)
      end
    end

    test "the task aborts and names both files on duplicate identity", ctx do
      write_artifact(ctx.dir, "ccc/docs/architecture.gen.json", havi_model())

      assert_raise Mix.Error, ~r/duplicate app identity "havi"/, fn ->
        Task.emit(ctx.manifest, false)
      end
    end
  end

  defp write_artifact(dir, rel, model) do
    File.write!(Path.join(dir, rel), Model.encode(model))
  end
end
