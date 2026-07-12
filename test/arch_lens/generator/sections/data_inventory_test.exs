defmodule ArchLens.Generator.Sections.DataInventoryTest do
  use ExUnit.Case, async: true

  alias ArchLens.Generator.Document
  alias ArchLens.Generator.Sections.DataInventory

  # A pre-joined bucket in the exact shape `ArchLens.Generator.Model.data_inventory/1`
  # emits (atom-keyed, contexts + resources already sorted), one row per posture.
  defp unassigned_bucket do
    %{
      context: "(unassigned)",
      context_source: "unassigned",
      resources: [
        %{
          module: "ArchLens.ModelV3Fixtures.CategoriesResource",
          posture: "declared",
          categories: ["financial", "organization"]
        },
        %{module: "ArchLens.ModelV3Fixtures.ExemptResource", posture: "exempt", categories: []},
        %{
          module: "ArchLens.ModelV3Fixtures.LegacyResource",
          posture: "declared",
          categories: ["contact"]
        },
        %{
          module: "ArchLens.TestSupport.NoPersonalDataResource",
          posture: "no_personal_data",
          categories: []
        }
      ],
      categories: ["contact", "financial", "organization"]
    }
  end

  defp render(entries), do: entries |> DataInventory.render() |> Enum.join("\n")

  describe "heading/0" do
    test "is the fixed `## Data inventory` heading" do
      assert DataInventory.heading() == "## Data inventory"
    end
  end

  describe "render/1 empty state" do
    test "an empty inventory renders nothing, so the section is dropped from the document" do
      assert DataInventory.render([]) == []
    end
  end

  describe "render/1 tables" do
    test "one context becomes a `### <context>` sub-section with a Resource/Categories table" do
      assert DataInventory.render([unassigned_bucket()]) == [
               "## Data inventory",
               "",
               "### (unassigned)",
               "",
               "| Resource | Categories |",
               "| --- | --- |",
               "| `ArchLens.ModelV3Fixtures.CategoriesResource` | `financial, organization` |",
               "| `ArchLens.ModelV3Fixtures.ExemptResource` | _exempt_ |",
               "| `ArchLens.ModelV3Fixtures.LegacyResource` | `contact` |",
               "| `ArchLens.TestSupport.NoPersonalDataResource` | _no personal data_ |"
             ]
    end

    test "each posture renders a distinct, honest Categories cell" do
      md = render([unassigned_bucket()])

      # declared → verbatim, sorted categories, comma-joined in one backtick span
      assert md =~ "| `ArchLens.ModelV3Fixtures.CategoriesResource` | `financial, organization` |"
      assert md =~ "| `ArchLens.ModelV3Fixtures.LegacyResource` | `contact` |"
      # escape hatches stay visible in the artifact, never silently dropped
      assert md =~ "| `ArchLens.ModelV3Fixtures.ExemptResource` | _exempt_ |"
      assert md =~ "| `ArchLens.TestSupport.NoPersonalDataResource` | _no personal data_ |"
    end

    test "an undeclared posture renders `_undeclared_`" do
      bucket = %{
        context: "Accounts",
        context_source: "domain",
        resources: [%{module: "App.Accounts.Ghost", posture: "undeclared", categories: []}],
        categories: []
      }

      assert render([bucket]) =~ "| `App.Accounts.Ghost` | _undeclared_ |"
    end

    test "a declared posture with no categories falls back to its posture verbatim, never a guess" do
      bucket = %{
        context: "Accounts",
        context_source: "domain",
        resources: [%{module: "App.Accounts.Odd", posture: "declared", categories: []}],
        categories: []
      }

      assert render([bucket]) =~ "| `App.Accounts.Odd` | _declared_ |"
    end

    test "multiple contexts are separated by a blank line and preserve the model's order" do
      accounts = %{
        context: "Accounts",
        context_source: "domain",
        resources: [%{module: "App.Accounts.User", posture: "declared", categories: ["contact"]}],
        categories: ["contact"]
      }

      billing = %{
        context: "Billing",
        context_source: "context_module",
        resources: [
          %{module: "App.Billing.Invoice", posture: "declared", categories: ["financial"]}
        ],
        categories: ["financial"]
      }

      assert DataInventory.render([accounts, billing]) == [
               "## Data inventory",
               "",
               "### Accounts",
               "",
               "| Resource | Categories |",
               "| --- | --- |",
               "| `App.Accounts.User` | `contact` |",
               "",
               "### Billing",
               "",
               "| Resource | Categories |",
               "| --- | --- |",
               "| `App.Billing.Invoice` | `financial` |"
             ]
    end
  end

  describe "to_json/1" do
    test "stringifies the pre-joined buckets into JSON-safe maps" do
      [bucket] = DataInventory.to_json([unassigned_bucket()])

      assert bucket["context"] == "(unassigned)"
      assert bucket["context_source"] == "unassigned"
      assert bucket["categories"] == ["contact", "financial", "organization"]

      assert Enum.map(bucket["resources"], & &1["posture"]) ==
               ["declared", "exempt", "declared", "no_personal_data"]

      # A JSON-safe structure encodes without raising.
      assert is_binary(Jason.encode!(bucket))
    end
  end

  describe "integration through ArchLens.Generator.Document" do
    test "the section slots into the assembled document with the exempt escape hatch visible" do
      model = %{
        resources: [],
        edges: [],
        oban_workers: [],
        entry_points: [],
        runtime_components: [],
        external_systems: [],
        context_dependencies: [],
        flows: [],
        data_inventory: [unassigned_bucket()],
        decisions: [],
        declared_architecture: [],
        app: []
      }

      md = Document.render(model)

      assert md =~ "## Data inventory"
      assert md =~ "### (unassigned)"
      assert md =~ "| Resource | Categories |"
      assert md =~ "| `ArchLens.ModelV3Fixtures.ExemptResource` | _exempt_ |"
      # rendered as one section, ends with a single trailing newline
      assert String.ends_with?(md, "_no personal data_ |\n")
    end
  end
end
