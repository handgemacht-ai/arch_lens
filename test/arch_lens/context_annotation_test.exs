defmodule ArchLens.ContextAnnotationTest do
  # Readers for the two in-place context annotations — `ArchLens.Domain` on an
  # Ash.Domain and `use ArchLens.Context` on a plain root module — plus the shared
  # name derivation. Driven against realistically compiled fixtures
  # (`ArchLens.CtxFixtures`) so the `@moduledoc` fallback reads a genuine docs chunk.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.Context
  alias ArchLens.Context.Info, as: ContextInfo
  alias ArchLens.Domain

  alias ArchLens.CtxFixtures.{
    Accounts,
    Billing,
    Excluded,
    Ingest,
    Judge,
    Renamed,
    Telemetry,
    Undescribed
  }

  describe "ArchLens.Domain reader — a domain with an explicit does" do
    test "reads the annotation, tags the source, and derives the name" do
      assert Domain.annotated?(Accounts)
      assert Domain.does(Accounts) == {"users, workspaces, and memberships", :annotation}
      assert Domain.name(Accounts) == :accounts
      assert Domain.described?(Accounts)
      refute Domain.excluded?(Accounts)
    end

    test "the explicit does wins over the module's @moduledoc" do
      {does, source} = Domain.does(Accounts)
      assert source == :annotation
      refute does =~ "ignored"
    end
  end

  describe "ArchLens.Domain reader — fallbacks" do
    test "a domain with the extension but no does falls back to the @moduledoc" do
      assert Domain.does(Billing) ==
               {"Subscriptions, invoices, and Stripe webhooks.", :moduledoc}

      assert Domain.name(Billing) == :billing
      assert Domain.described?(Billing)
    end

    test "an excluded domain is excluded and not required to be described" do
      assert Domain.excluded?(Telemetry)
      refute Domain.described?(Telemetry)
    end

    test "a domain without the extension is unannotated and undescribed" do
      refute Domain.annotated?(Undescribed)
      refute Domain.excluded?(Undescribed)
      refute Domain.described?(Undescribed)
      assert Domain.does(Undescribed) == {nil, nil}
    end
  end

  describe "ArchLens.Context.Info reader — a plain annotated module" do
    test "reads the annotated does over the @moduledoc and derives the name" do
      assert ContextInfo.annotated?(Judge)
      assert ContextInfo.does(Judge) == {"scores copy against the brand judges", :annotation}
      assert ContextInfo.name(Judge) == :judge
      assert ContextInfo.described?(Judge)
      refute ContextInfo.excluded?(Judge)
    end

    test "an explicit name: overrides the derived name" do
      assert ContextInfo.name(Renamed) == :custom_name
    end

    test "exclude: true is honoured and does not require a description" do
      assert ContextInfo.excluded?(Excluded)
      refute ContextInfo.described?(Excluded)
    end
  end

  describe "ArchLens.Context.Info reader — a plain module with only a @moduledoc" do
    test "an unannotated folder root falls back to its @moduledoc" do
      refute ContextInfo.annotated?(Ingest)

      assert ContextInfo.does(Ingest) ==
               {"Ingests raw events from the edge and normalises them.", :moduledoc}

      assert ContextInfo.name(Ingest) == :ingest
      assert ContextInfo.described?(Ingest)
    end
  end

  describe "ArchLens.Context.derive_name/1" do
    test "snake-cases the last segment" do
      assert Context.derive_name(MyApp.Accounts) == :accounts
      assert Context.derive_name(MyApp.FeatureFlags) == :feature_flags
    end

    test "drops a generic leaf (Data / Domain / Store) in favour of the segment before it" do
      assert Context.derive_name(MyApp.Billing.Store) == :billing
      assert Context.derive_name(MyApp.Accounts.Domain) == :accounts
      assert Context.derive_name(MyApp.Sessions.Data) == :sessions
    end

    test "a single-segment generic name keeps itself (nothing before it)" do
      assert Context.derive_name(Store) == :store
    end
  end

  describe "use ArchLens.Context validates its options at compile time" do
    test "a non-literal / wrong-typed option fails the compile fast" do
      code = """
      defmodule ArchLens.ContextAnnotationTest.BadOptFixture do
        use ArchLens.Context, does: 123
      end
      """

      assert_raise ArgumentError, ~r/expects a literal value for `does`/, fn ->
        capture_io(:stderr, fn -> Code.compile_string(code) end)
      end
    end
  end
end
