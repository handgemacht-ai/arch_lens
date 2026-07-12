# Inline fixtures for the v3 model tests. Defining Ash resources / Oban workers at
# test runtime emits benign "Inspect protocol already consolidated" warnings.

defmodule ArchLens.ModelV3Fixtures.CategoriesResource do
  @moduledoc false
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false, extensions: [ArchLens.Privacy]

  privacy do
    categories([:organization, :financial])
    retention("P30D")
    legal_basis(:contract)
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.ModelV3Fixtures.LegacyResource do
  @moduledoc false
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false, extensions: [ArchLens.Privacy]

  privacy do
    data_category(:contact)
    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.ModelV3Fixtures.ExemptResource do
  @moduledoc false
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false, extensions: [ArchLens.Privacy]

  privacy_exempt do
    reason("legacy import table, scheduled for deletion")
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.ModelV3Fixtures.Mailer do
  @moduledoc false
  use Oban.Worker, queue: :mailers

  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule ArchLens.Generator.ModelV3Test do
  # async: false — resolves scopes and loads modules; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Generator.{Document, Model, Scope}
  alias ArchLens.ModelV3Fixtures.{CategoriesResource, ExemptResource, LegacyResource, Mailer}
  alias ArchLens.System.ExternalMerge
  alias ArchLens.TestSupport.NoPersonalDataResource

  @fixture_dir Path.join([__DIR__, "..", "..", "fixtures", "v3_empty"])

  # The canonical fully-empty v3 scope — the same opts the committed golden
  # fixtures were generated from.
  defp empty_opts do
    [
      app: :arch_lens,
      domains: [],
      scanned_resources: [],
      modules: [],
      edges: [],
      oban_workers: [],
      entry_points: [],
      runtime_components: [],
      external_systems: [],
      declared_architecture: [],
      dependency_refs: [],
      deps: [],
      cron: %{},
      ignore_externals: [],
      decisions: [],
      decision_errors: []
    ]
  end

  defp populated_opts do
    [
      app: :arch_lens,
      domains: [],
      scanned_resources: [
        CategoriesResource,
        LegacyResource,
        ExemptResource,
        NoPersonalDataResource
      ],
      modules: [],
      edges: [],
      oban_workers: [Mailer],
      cron: %{Mailer => ["0 3 * * *"]},
      entry_points: [],
      runtime_components: [],
      external_systems: [],
      declared_architecture: [],
      dependency_refs: [],
      deps: [],
      ignore_externals: [],
      decisions: [],
      decision_errors: []
    ]
  end

  defp decoded(opts), do: opts |> Scope.resolve() |> Model.to_json() |> Jason.decode!()

  defp find_resource(model, module) do
    id = "res:" <> inspect(module)
    Enum.find(model["resources"], &(&1["id"] == id))
  end

  describe "empty-v3 golden baseline" do
    test "the empty scope renders byte-identically to the committed JSON fixture" do
      json = Model.to_json(Scope.resolve(empty_opts()))
      assert json == File.read!(Path.join(@fixture_dir, "architecture.gen.json"))
    end

    test "the empty scope renders byte-identically to the committed Markdown fixture" do
      md = empty_opts() |> Scope.resolve() |> Model.to_map() |> Document.render()
      assert md == File.read!(Path.join(@fixture_dir, "architecture.gen.md"))
    end

    test "generating twice from the same empty scope is byte-identical" do
      assert Model.to_json(Scope.resolve(empty_opts())) ==
               Model.to_json(Scope.resolve(empty_opts()))
    end
  end

  describe "schema v3 shape" do
    test "the model stamps schema_version 3" do
      assert decoded(empty_opts())["schema_version"] == 3
    end

    test "every v3 top-level key is present" do
      model = decoded(empty_opts())

      for key <- ~w(
            schema_version app resources edges oban_workers entry_points
            runtime_components external_systems context_dependencies flows
            data_inventory decisions declared_architecture
          ) do
        assert Map.has_key?(model, key), "missing top-level key #{key}"
      end
    end

    test "the new list keys default to empty and carry no fabricated entries" do
      model = decoded(empty_opts())

      assert model["context_dependencies"] == []
      assert model["flows"] == []
      assert model["data_inventory"] == []
      assert model["decisions"] == []
    end
  end

  describe "app identity block" do
    test "an app with no declared identity is collected from the OTP app name" do
      assert decoded(empty_opts())["app"] == %{"id" => "arch_lens", "source" => "collected"}
    end

    test "a declared identity wins and carries its name and aliases" do
      identity = %{
        identity: %{id: :havi, name: "Havi", aliases: ["havi", "havi.handgemacht.ai"]},
        actors: [],
        externals: [],
        contexts: [],
        flows: [],
        warnings: []
      }

      model = decoded(Keyword.put(empty_opts(), :declared_architecture, identity))

      assert model["app"] == %{
               "id" => "havi",
               "name" => "Havi",
               "aliases" => ["havi", "havi.handgemacht.ai"],
               "source" => "declared"
             }
    end
  end

  describe "privacy categories (v3 rename, backward compatible)" do
    test "a v3 declaration renders a sorted categories list, not a singular field" do
      privacy = find_resource(decoded(populated_opts()), CategoriesResource)["privacy"]

      assert privacy["posture"] == "declared"
      assert privacy["categories"] == ["financial", "organization"]
      refute Map.has_key?(privacy, "data_category")
    end

    test "a legacy singular declaration still renders under data_category" do
      privacy = find_resource(decoded(populated_opts()), LegacyResource)["privacy"]

      assert privacy["posture"] == "declared"
      assert privacy["data_category"] == "contact"
      refute Map.has_key?(privacy, "categories")
    end

    test "an exempt resource renders posture exempt with its verbatim reason" do
      privacy = find_resource(decoded(populated_opts()), ExemptResource)["privacy"]

      assert privacy["posture"] == "exempt"
      assert privacy["reason"] == "legacy import table, scheduled for deletion"
    end

    test "Markdown renders each posture surface distinctly" do
      md = populated_opts() |> Scope.resolve() |> Model.to_map() |> Document.render()

      assert md =~ "- Categories: `financial, organization`"
      assert md =~ "- Data category: `:contact`"
      assert md =~ "- **Exempt from classification:** legacy import table, scheduled for deletion"
    end
  end

  describe "data inventory join (derived view)" do
    test "resources with no Ash domain group under the unassigned bucket" do
      inventory = decoded(populated_opts())["data_inventory"]

      assert [bucket] = inventory
      assert bucket["context"] == "(unassigned)"
      assert bucket["context_source"] == "unassigned"
    end

    test "the bucket's category union is the sorted union across its resources" do
      [bucket] = decoded(populated_opts())["data_inventory"]

      assert bucket["categories"] == ["contact", "financial", "organization"]
    end

    test "each resource row carries its module, posture, and categories, module-sorted" do
      [bucket] = decoded(populated_opts())["data_inventory"]

      rows = Enum.map(bucket["resources"], &{&1["module"], &1["posture"], &1["categories"]})

      assert rows == [
               {"ArchLens.ModelV3Fixtures.CategoriesResource", "declared",
                ["financial", "organization"]},
               {"ArchLens.ModelV3Fixtures.ExemptResource", "exempt", []},
               {"ArchLens.ModelV3Fixtures.LegacyResource", "declared", ["contact"]},
               {"ArchLens.TestSupport.NoPersonalDataResource", "no_personal_data", []}
             ]
    end
  end

  describe "oban worker queue + cron enrichment" do
    test "a worker carries its declared queue and the cron schedules that trigger it" do
      worker =
        Enum.find(decoded(populated_opts())["oban_workers"], &(&1["module"] =~ "Mailer"))

      assert worker["queue"] == "mailers"
      assert worker["cron"] == ["0 3 * * *"]
    end

    test "a worker not triggered by cron carries an empty cron list" do
      opts = Keyword.put(populated_opts(), :cron, %{})
      worker = Enum.find(decoded(opts)["oban_workers"], &(&1["module"] =~ "Mailer"))

      assert worker["queue"] == "mailers"
      assert worker["cron"] == []
    end

    test "Markdown decorates each Oban worker line with its queue" do
      md = populated_opts() |> Scope.resolve() |> Model.to_map() |> Document.render()

      assert md =~ "- `ArchLens.ModelV3Fixtures.Mailer` [queue: mailers]"
    end
  end

  describe "ExternalMerge.merge/3 verification stamp" do
    test "a declared+collected external is corroborated" do
      collected = [%{id: "external:stripe", target: "https://api.stripe.com", vendor: "Stripe"}]
      declared = [%{name: "Stripe", target: "https://api.stripe.com", via: :req, does: "billing"}]

      [element] = ExternalMerge.merge(collected, declared, [])

      assert element.provenance == ["collected", "declared"]
      assert element.verification == "corroborated"
    end

    test "a declared-only external is manual" do
      declared = [%{name: "Brevo", target: "https://api.brevo.com", via: :req, does: "email"}]

      [element] = ExternalMerge.merge([], declared, [])

      assert element.provenance == ["declared"]
      assert element.verification == "manual"
    end
  end
end
