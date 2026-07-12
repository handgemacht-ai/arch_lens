# Happy-path fixtures are real Ash resources defined inline (rather than a
# separate helper file), so they load as part of this `_test.exs`. Defining Ash
# resources at test runtime emits benign "Inspect protocol already consolidated"
# warnings — harmless, and unavoidable since these fixtures can only live under
# the owned test path.

defmodule ArchLens.Privacy.VocabularyResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    categories([:contact, :content])
    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule ArchLens.Privacy.EveryCategoryResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    categories([
      :contact,
      :identifier,
      :credential,
      :content,
      :usage,
      :consent,
      :organization,
      :financial,
      :profile,
      :membership
    ])

    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule ArchLens.Privacy.LegacyCategoryResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:contact)
    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule ArchLens.Privacy.ExemptResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy_exempt do
    reason("legacy import table, scheduled for deletion in Q3")
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule ArchLens.Privacy.VocabularyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.Privacy
  alias ArchLens.Privacy.Info

  alias ArchLens.Privacy.{
    EveryCategoryResource,
    ExemptResource,
    LegacyCategoryResource,
    VocabularyResource
  }

  describe "closed category vocabulary" do
    test "the governed vocabulary is the ten agreed categories, in order" do
      assert Privacy.categories() == [
               :contact,
               :identifier,
               :credential,
               :content,
               :usage,
               :consent,
               :organization,
               :financial,
               :profile,
               :membership
             ]
    end

    test "a list-valued categories declaration is read back as declared" do
      assert Info.categories(VocabularyResource) == [:contact, :content]
      assert Info.retention(VocabularyResource) == "P30D"
      assert Info.legal_basis(VocabularyResource) == :consent
      assert Info.declared?(VocabularyResource)
      refute Info.no_personal_data?(VocabularyResource)
      refute Info.exempt?(VocabularyResource)
    end

    test "every category in the closed vocabulary is accepted" do
      assert Info.categories(EveryCategoryResource) == Privacy.categories()
    end

    test "posture is the declaration for a classified resource" do
      assert %Privacy.Declaration{categories: [:contact, :content]} =
               Info.posture(VocabularyResource)
    end
  end

  describe "vocabulary gate (Spark {:list, {:one_of, …}})" do
    test "an out-of-vocabulary category fails compilation" do
      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_string(resource_with_categories("BadCategoryFixture", "[:biometric]"))
        end
      end)
    end

    test "a partly-invalid category list fails compilation" do
      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_string(
            resource_with_categories("MixedCategoryFixture", "[:contact, :genetic]")
          )
        end
      end)
    end
  end

  describe "non-empty gate (PersistPrivacy)" do
    test "an empty categories list fails compilation" do
      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/non-empty/, fn ->
          Code.compile_string(resource_with_categories("EmptyCategoryFixture", "[]"))
        end
      end)
    end

    test "a privacy block with no category form fails compilation" do
      code = """
      defmodule ArchLens.Privacy.VocabularyTest.NoCategoryFixture do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [ArchLens.Privacy]

        privacy do
          retention "P30D"
          legal_basis :consent
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end

  describe "legacy data_category alias" do
    test "still declares a classified resource" do
      assert Info.data_category(LegacyCategoryResource) == :contact
      assert Info.categories(LegacyCategoryResource) == nil
      assert Info.declared?(LegacyCategoryResource)

      assert %Privacy.Declaration{data_category: :contact} =
               Info.posture(LegacyCategoryResource)
    end
  end

  describe "reason-bearing privacy_exempt posture" do
    test "Info exposes the exemption and its reason" do
      assert Info.exempt?(ExemptResource)

      assert Info.exempt_reason(ExemptResource) ==
               "legacy import table, scheduled for deletion in Q3"

      assert Info.declared?(ExemptResource)
      refute Info.no_personal_data?(ExemptResource)
      assert Info.declaration(ExemptResource) == nil
      assert Info.categories(ExemptResource) == nil
    end

    test "posture is {:exempt, reason}" do
      assert Info.posture(ExemptResource) ==
               {:exempt, "legacy import table, scheduled for deletion in Q3"}
    end

    test "a missing reason fails compilation" do
      code = """
      defmodule ArchLens.Privacy.VocabularyTest.ExemptNoReasonFixture do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [ArchLens.Privacy]

        privacy_exempt do
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_string(code)
        end
      end)
    end

    test "a blank reason fails compilation" do
      code = """
      defmodule ArchLens.Privacy.VocabularyTest.ExemptBlankReasonFixture do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [ArchLens.Privacy]

        privacy_exempt do
          reason "   "
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/non-blank/, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end

  describe "three-way mutual exclusion (PersistPrivacy)" do
    test "privacy and no_personal_data are mutually exclusive" do
      assert_multiple_declared("""
      privacy do
        categories [:contact]
        retention "P30D"
        legal_basis :consent
      end

      no_personal_data do
      end
      """)
    end

    test "privacy and privacy_exempt are mutually exclusive" do
      assert_multiple_declared("""
      privacy do
        categories [:contact]
        retention "P30D"
        legal_basis :consent
      end

      privacy_exempt do
        reason "cannot be both classified and exempt"
      end
      """)
    end

    test "no_personal_data and privacy_exempt are mutually exclusive" do
      assert_multiple_declared("""
      no_personal_data do
      end

      privacy_exempt do
        reason "cannot be both empty and exempt"
      end
      """)
    end
  end

  defp resource_with_categories(name, categories_literal) do
    """
    defmodule ArchLens.Privacy.VocabularyTest.#{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [ArchLens.Privacy]

      privacy do
        categories #{categories_literal}
        retention "P30D"
        legal_basis :consent
      end
    end
    """
  end

  defp assert_multiple_declared(body) do
    fixture = :erlang.unique_integer([:positive])

    code = """
    defmodule ArchLens.Privacy.VocabularyTest.MutualExclusion#{fixture} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [ArchLens.Privacy]

      #{body}
    end
    """

    capture_io(:stderr, fn ->
      assert_raise Spark.Error.DslError, ~r/not both/, fn ->
        Code.compile_string(code)
      end
    end)
  end
end
