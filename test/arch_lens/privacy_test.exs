defmodule ArchLens.PrivacyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.Generator.{Document, Model, Scope}
  alias ArchLens.Privacy.{Declaration, Info}

  alias ArchLens.TestSupport.{
    ExemptResource,
    NoPersonalDataResource,
    UndeclaredResource,
    ValidPrivacyResource
  }

  @exempt_reason "legacy import table, no PII collected"

  describe "a resource with a valid privacy block" do
    test "Info reads the whole declaration back" do
      assert %Declaration{data_category: :contact, retention: "P30D", legal_basis: :consent} =
               Info.declaration(ValidPrivacyResource)
    end

    test "Info exposes each field" do
      assert Info.data_category(ValidPrivacyResource) == :contact
      assert Info.retention(ValidPrivacyResource) == "P30D"
      assert Info.legal_basis(ValidPrivacyResource) == :consent
    end

    test "the resource is declared and not marked no_personal_data" do
      assert Info.declared?(ValidPrivacyResource)
      refute Info.no_personal_data?(ValidPrivacyResource)
      assert %Declaration{} = Info.posture(ValidPrivacyResource)
    end
  end

  describe "a resource that declares no_personal_data instead of a privacy block" do
    test "Info reports no personal data and carries no declaration" do
      assert Info.no_personal_data?(NoPersonalDataResource)
      assert Info.declaration(NoPersonalDataResource) == nil
      assert Info.data_category(NoPersonalDataResource) == nil
    end

    test "the resource is declared with a :no_personal_data posture" do
      assert Info.declared?(NoPersonalDataResource)
      assert Info.posture(NoPersonalDataResource) == :no_personal_data
    end
  end

  describe "a resource that declares privacy_exempt instead of a privacy block" do
    test "Info reports the exempt reason and carries no declaration" do
      assert Info.exempt?(ExemptResource)
      assert Info.exempt_reason(ExemptResource) == @exempt_reason
      assert Info.declaration(ExemptResource) == nil
      refute Info.no_personal_data?(ExemptResource)
    end

    test "the resource is declared with an {:exempt, reason} posture" do
      assert Info.declared?(ExemptResource)
      assert Info.posture(ExemptResource) == {:exempt, @exempt_reason}
    end

    test "generation renders the exempt posture in both the JSON and Markdown artifacts" do
      scope = Scope.resolve(exempt_scope_opts())

      privacy =
        scope
        |> Model.to_json()
        |> Jason.decode!()
        |> Map.fetch!("resources")
        |> Enum.find(&(&1["id"] == "res:" <> inspect(ExemptResource)))
        |> Map.fetch!("privacy")

      assert privacy == %{"posture" => "exempt", "reason" => @exempt_reason}

      md = scope |> Model.to_map() |> Document.render()

      assert md =~ "### #{inspect(ExemptResource)}"
      assert md =~ "- **Exempt from classification:** #{@exempt_reason}"
    end
  end

  describe "a resource that adds the extension but declares nothing" do
    test "posture is :undeclared" do
      refute Info.declared?(UndeclaredResource)
      assert Info.declaration(UndeclaredResource) == nil
      refute Info.no_personal_data?(UndeclaredResource)
      assert Info.posture(UndeclaredResource) == :undeclared
    end
  end

  describe "a resource that declares both a privacy block and no_personal_data" do
    test "is rejected at compile time" do
      code = """
      defmodule ArchLens.PrivacyTest.BothDeclaredFixture do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [ArchLens.Privacy]

        privacy do
          data_category :contact
          retention "P30D"
          legal_basis :consent
        end

        no_personal_data do
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/not both/, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end

  # A fully-explicit, collector-free scope carrying just the exempt fixture, so
  # generation is deterministic and no default collector runs.
  defp exempt_scope_opts do
    [
      app: :arch_lens,
      domains: [],
      scanned_resources: [ExemptResource],
      modules: [],
      edges: [],
      oban_workers: [],
      cron: %{},
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
end
