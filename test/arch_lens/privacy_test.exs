defmodule ArchLens.PrivacyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.Privacy.{Declaration, Info}

  alias ArchLens.TestSupport.{
    NoPersonalDataResource,
    UndeclaredResource,
    ValidPrivacyResource
  }

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
end
