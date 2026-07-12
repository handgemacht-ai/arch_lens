defmodule ArchLens.Generator.NamespaceTest do
  # The shared namespace logic extracted from `ArchLens.Generator.Contexts`: the
  # folder-namespace helpers the style gate reads, and the module-attribution index
  # (segment + exact-module) the cross-context edge/flow/entry-point slices consume.
  # Driven through explicitly-built `Scope` structs over the realistically compiled
  # `ArchLens.CtxFixtures` app. async: false — one case resolves a central
  # declaration, which emits a deprecation warning to stderr.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ArchLens.CtxFixtures
  alias ArchLens.CtxFixtures.{Accounts, Blog}
  alias ArchLens.Generator.{Contexts, Model, Namespace, Scope}

  defp scope(overrides) do
    defaults = [
      resources: [],
      app_namespace: CtxFixtures.app_namespace(),
      modules: CtxFixtures.healthy_modules(),
      domains: CtxFixtures.domains()
    ]

    struct!(Scope, Keyword.merge(defaults, overrides))
  end

  defp flat_modules(extra), do: CtxFixtures.healthy_modules() ++ extra

  defp resolved(scope), do: scope |> Contexts.resolve() |> Map.fetch!(:contexts)

  defp index(scope), do: Namespace.context_index(scope, resolved(scope))

  describe "folder_namespaces/1" do
    test "returns the child-bearing top-level segments under the app namespace, sorted" do
      # Every healthy folder root has children; Telemetry is a childless domain module.
      assert Namespace.folder_namespaces(scope([])) ==
               ["Accounts", "Billing", "Excluded", "Ingest", "Judge", "Renamed"]
    end

    test "ignore_namespaces drops a segment, matching its intuitive mixed-case spelling" do
      modules = CtxFixtures.healthy_modules() ++ [CtxFixtures.E2E.Spec]

      assert "E2E" in Namespace.folder_namespaces(scope(modules: modules))

      # `:e2e` (not the Macro.underscore-mangled `:e2_e`) excuses the E2E folder.
      refute "E2E" in Namespace.folder_namespaces(
               scope(modules: modules, ignore_namespaces: [:e2e])
             )
    end

    test "returns [] when the app namespace is unavailable" do
      assert Namespace.folder_namespaces(scope(app_namespace: nil)) == []
    end
  end

  describe "root_module/2" do
    test "concatenates the app namespace with the segment" do
      assert Namespace.root_module(scope([]), "Accounts") == Accounts
    end
  end

  describe "Contexts.resolve/1 emits id and module" do
    test "an in-place context carries a context: id and its annotated module" do
      accounts = Enum.find(resolved(scope([])), &(&1.name == :accounts))
      assert accounts.id == "context:accounts"
      assert accounts.module == Accounts

      judge = Enum.find(resolved(scope([])), &(&1.name == :judge))
      assert judge.id == "context:judge"
      assert judge.module == CtxFixtures.Judge

      # A name: override still ids and modules honestly (name is custom, module is real).
      renamed = Enum.find(resolved(scope([])), &(&1.name == :custom_name))
      assert renamed.id == "context:custom_name"
      assert renamed.module == CtxFixtures.Renamed
    end

    test "the id and module survive into the JSON model as strings" do
      json =
        scope([])
        |> Model.to_map()
        |> Model.encode()
        |> Jason.decode!()

      accounts =
        json["declared_architecture"]["contexts"] |> Enum.find(&(&1["name"] == "accounts"))

      assert accounts["id"] == "context:accounts"
      assert accounts["module"] == "ArchLens.CtxFixtures.Accounts"
    end

    test "a deprecated central declaration is ided but carries no module" do
      central = %{contexts: [%{name: :legacy, does: "an old context", modules: "X"}]}

      capture_io(:stderr, fn ->
        send(self(), {:contexts, resolved(scope(declared_architecture: central))})
      end)

      assert_received {:contexts, contexts}
      legacy = Enum.find(contexts, &(&1.name == :legacy))
      assert legacy.id == "context:legacy"
      assert legacy.origin == :central_declared
      refute Map.has_key?(legacy, :module)
    end
  end

  describe "context_index/2 + attribute/2 — folder-root and domain contexts own their segment" do
    test "a domain attributes its own module and every resource under it" do
      index = index(scope([]))

      assert Namespace.attribute(index, Accounts) == :accounts
      assert Namespace.attribute(index, Accounts.User) == :accounts
      assert Namespace.attribute(index, Accounts.Workspace) == :accounts
    end

    test "a folder-root context module attributes its children, honouring a name override" do
      index = index(scope([]))

      assert Namespace.attribute(index, CtxFixtures.Judge.Scorer) == :judge
      assert Namespace.attribute(index, CtxFixtures.Ingest.Parser) == :ingest
      assert Namespace.attribute(index, CtxFixtures.Renamed.Worker) == :custom_name
    end

    test "an excluded context's segment is unattributed, never guessed" do
      # Excluded/Helper form a folder, but the Excluded context is exclude: true, so
      # no resolved context claims the segment — its modules attribute to nil.
      index = index(scope([]))

      assert Namespace.attribute(index, CtxFixtures.Excluded) == nil
      assert Namespace.attribute(index, CtxFixtures.Excluded.Helper) == nil
    end

    test "a module outside any context, and the app root itself, attribute to nil" do
      index = index(scope([]))

      assert Namespace.attribute(index, Enum) == nil
      assert Namespace.attribute(index, CtxFixtures) == nil
      assert Namespace.attribute(index, CtxFixtures.Telemetry) == nil
    end
  end

  describe "context_index/2 + attribute/2 — flat childless contexts own only their exact module" do
    test "a flat context attributes its exact module but not a would-be child" do
      index = index(scope(modules: flat_modules([Blog])))

      assert Namespace.attribute(index, Blog) == :blog
      # Blog has no children folder, so a nested module is NOT the flat context's.
      assert Namespace.attribute(index, Module.concat(Blog, :Sub)) == nil
    end
  end

  describe "attribute/2 — precedence" do
    test "an exact-module match wins over a segment match" do
      index = %{
        app_namespace: CtxFixtures,
        segments: %{"Accounts" => :segment_owner},
        exact: %{Accounts.User => :exact_owner},
        modules: []
      }

      assert Namespace.attribute(index, Accounts.User) == :exact_owner
      assert Namespace.attribute(index, Accounts.Workspace) == :segment_owner
    end
  end

  describe "membership/1" do
    test "materialises module => context for every attributed scope module" do
      membership = Namespace.membership(index(scope([])))

      assert membership[Accounts] == :accounts
      assert membership[Accounts.User] == :accounts
      assert membership[Accounts.Workspace] == :accounts
      assert membership[CtxFixtures.Billing] == :billing
      assert membership[CtxFixtures.Billing.Invoice] == :billing
      assert membership[CtxFixtures.Judge] == :judge
      assert membership[CtxFixtures.Judge.Scorer] == :judge
      assert membership[CtxFixtures.Ingest] == :ingest
      assert membership[CtxFixtures.Renamed.Worker] == :custom_name
    end

    test "unattributed modules are absent, never mapped to nil" do
      membership = Namespace.membership(index(scope([])))

      refute Map.has_key?(membership, CtxFixtures)
      refute Map.has_key?(membership, CtxFixtures.Telemetry)
      refute Map.has_key?(membership, CtxFixtures.Excluded.Helper)
      refute Enum.any?(membership, fn {_module, name} -> is_nil(name) end)
    end

    test "is deterministic across runs" do
      assert Namespace.membership(index(scope([]))) == Namespace.membership(index(scope([])))
    end
  end
end
