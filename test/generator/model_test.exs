# Inline fixtures for the model tests: a resource whose retention is genuinely
# enforced (an expiry attribute plus a cleanup edge), alongside the shared
# test-support resources. Defining Ash resources at test runtime emits benign
# "Inspect protocol already consolidated" warnings.

defmodule ArchLens.ModelFixtures.Session do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:session)
    retention("P30D")
    legal_basis(:contract)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:expires_at, :utc_datetime_usec)
  end
end

defmodule ArchLens.Generator.ModelTest do
  # async: false — resolves scopes and loads modules; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Edge
  alias ArchLens.Generator.{Document, Model, Scope}

  defp opts do
    [
      domains: [],
      scanned_resources: [
        ArchLens.ModelFixtures.Session,
        ArchLens.TestSupport.ValidPrivacyResource,
        ArchLens.TestSupport.NoPersonalDataResource
      ],
      edges: [
        %Edge{
          kind: :oban_insert,
          builder: ArchLens.ModelFixtures.PurgeSessions,
          call_sites: [{"lib/model_fixtures/session.ex", 9}],
          target: ArchLens.ModelFixtures.PurgeSessions,
          metadata: %{retention_cleanup_for: ArchLens.ModelFixtures.Session}
        },
        %Edge{
          kind: :http_boundary,
          builder: {ArchLens.ModelFixtures.Stripe, :stripe},
          call_sites: [{"lib/model_fixtures/stripe.ex", 3}],
          target: "https://api.stripe.com",
          metadata: %{via: :req}
        }
      ],
      oban_workers: [ArchLens.ModelFixtures.PurgeSessions]
    ]
  end

  defp decoded, do: opts() |> Scope.resolve() |> Model.to_json() |> Jason.decode!()

  describe "determinism" do
    test "generating the JSON model twice from unchanged code is byte-identical" do
      assert Model.to_json(Scope.resolve(opts())) == Model.to_json(Scope.resolve(opts()))
    end

    test "the JSON model carries no absolute filesystem path" do
      json = Model.to_json(Scope.resolve(opts()))

      refute json =~ File.cwd!()
      refute json =~ ~r{(^|[^a-z])/srv/}
      assert json =~ "lib/model_fixtures/session.ex"
    end
  end

  describe "schema + provenance" do
    test "the model stamps schema_version 1" do
      assert decoded()["schema_version"] == 1
    end

    test "every element carries a source: declared privacy rows, collected edges/workers" do
      model = decoded()

      assert Enum.all?(model["resources"], &(&1["source"] == "declared"))
      assert Enum.all?(model["edges"], &(&1["source"] == "collected"))
      assert Enum.all?(model["oban_workers"], &(&1["source"] == "collected"))
    end
  end

  describe "stable ids (no file:line in identity)" do
    test "resources and workers use kind-prefixed module ids" do
      model = decoded()

      assert "res:ArchLens.ModelFixtures.Session" in Enum.map(model["resources"], & &1["id"])

      assert "oban:ArchLens.ModelFixtures.PurgeSessions" in Enum.map(
               model["oban_workers"],
               & &1["id"]
             )
    end

    test "an edge's id is its kind+builder+target, with call sites carried as an attribute" do
      oban_edge = Enum.find(decoded()["edges"], &(&1["kind"] == "oban_insert"))

      assert oban_edge["id"] ==
               "edge:oban_insert:ArchLens.ModelFixtures.PurgeSessions=>ArchLens.ModelFixtures.PurgeSessions"

      assert oban_edge["call_sites"] == [
               %{"file" => "lib/model_fixtures/session.ex", "line" => 9}
             ]

      # The identity string carries no file or line.
      refute oban_edge["id"] =~ "session.ex"
      refute oban_edge["id"] =~ ~r/:\d/
    end
  end

  describe "structured retention" do
    test "an enforced retention is a {policy, enforcement, field, cleanup} map" do
      session =
        Enum.find(decoded()["resources"], &(&1["id"] == "res:ArchLens.ModelFixtures.Session"))

      retention = session["privacy"]["retention"]

      assert retention["policy"] == "P30D"
      assert retention["enforcement"] == "enforced"
      assert retention["field"] == "expires_at"
      assert retention["cleanup"] == "ArchLens.ModelFixtures.PurgeSessions"
    end

    test "a declared-but-unenforced retention keeps the prose policy and an unenforced label" do
      valid =
        Enum.find(
          decoded()["resources"],
          &(&1["id"] == "res:ArchLens.TestSupport.ValidPrivacyResource")
        )

      assert valid["privacy"]["retention"]["policy"] == "P30D"
      assert valid["privacy"]["retention"]["enforcement"] == "declared_not_enforced"
    end

    test "a no-personal-data resource has no retention" do
      npd =
        Enum.find(
          decoded()["resources"],
          &(&1["id"] == "res:ArchLens.TestSupport.NoPersonalDataResource")
        )

      assert npd["privacy"]["posture"] == "no_personal_data"
      refute Map.has_key?(npd["privacy"], "retention")
    end
  end

  describe "collected module doc" do
    # A dedicated opts set wiring realistically compiled fixtures across all three
    # extraction cases through the resource and Oban surfaces at once.
    defp doc_opts do
      [
        domains: [],
        scanned_resources: [ArchLens.TestSupport.DocumentedResource],
        edges: [],
        oban_workers: [
          ArchLens.ModuleDocFixtures.MultiParagraph,
          ArchLens.ModuleDocFixtures.DocFalse,
          ArchLens.ModuleDocFixtures.NoDoc
        ]
      ]
    end

    defp doc_decoded, do: doc_opts() |> Scope.resolve() |> Model.to_json() |> Jason.decode!()

    test "a resource surfaces only the first paragraph of its @moduledoc" do
      resource =
        Enum.find(
          doc_decoded()["resources"],
          &(&1["id"] == "res:ArchLens.TestSupport.DocumentedResource")
        )

      assert resource["doc"] ==
               "Stores contact submissions captured from the public marketing site."
    end

    test "an Oban worker with a moduledoc carries its first paragraph" do
      worker =
        Enum.find(
          doc_decoded()["oban_workers"],
          &(&1["id"] == "oban:ArchLens.ModuleDocFixtures.MultiParagraph")
        )

      assert worker["doc"] ==
               "Collects semantic review findings and writes them back to the annotation."
    end

    test "@moduledoc false and no-moduledoc modules omit the doc field entirely" do
      workers = doc_decoded()["oban_workers"]

      doc_false =
        Enum.find(workers, &(&1["id"] == "oban:ArchLens.ModuleDocFixtures.DocFalse"))

      no_doc =
        Enum.find(workers, &(&1["id"] == "oban:ArchLens.ModuleDocFixtures.NoDoc"))

      refute Map.has_key?(doc_false, "doc")
      refute Map.has_key?(no_doc, "doc")
    end

    test "the doc field is deterministic across two renders" do
      scope = Scope.resolve(doc_opts())
      assert Model.to_json(scope) == Model.to_json(scope)
    end

    test "markdown renders the resource's first sentence, not the whole paragraph" do
      markdown = doc_opts() |> Scope.resolve() |> Model.to_map() |> Document.render()

      assert markdown =~ "_Stores contact submissions captured from the public marketing site._"
      # the dropped second paragraph never reaches the document
      refute markdown =~ "internal retention mechanics"
    end
  end

  describe "follow-up-slice seams" do
    test "the four seams are present and empty by default" do
      model = decoded()

      assert model["entry_points"] == []
      assert model["runtime_components"] == []
      assert model["external_systems"] == []
      assert model["declared_architecture"] == []
    end

    test "a populated seam renders a Markdown section and serialises to JSON" do
      scope = Scope.resolve(Keyword.put(opts(), :entry_points, [%{label: "GET /health"}]))
      model = Model.to_map(scope)

      markdown = Document.render(model)
      assert markdown =~ "## Entry points"
      assert markdown =~ "GET /health"

      json = model |> Model.encode() |> Jason.decode!()
      assert json["entry_points"] == [%{"label" => "GET /health"}]
    end

    test "declared_architecture entries are tagged source: declared" do
      scope =
        Scope.resolve(
          Keyword.put(opts(), :declared_architecture, [%{label: "no cross-context calls"}])
        )

      assert [entry] =
               Model.to_json(scope) |> Jason.decode!() |> Map.fetch!("declared_architecture")

      assert entry["source"] == "declared"
      assert entry["label"] == "no cross-context calls"
    end
  end
end
