defmodule ArchLens.Generator.ContextsTest do
  # The context resolver and the two generation-time gates (style + annotation),
  # driven through explicitly-built `Scope` structs over the realistically compiled
  # `ArchLens.CtxFixtures` app. async: false — resolve/reconcile emit deprecation
  # warnings to stderr that a couple of cases capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ArchLens.CtxFixtures
  alias ArchLens.CtxFixtures.{Accounts, Bare, Fixtures, Orphan, Undescribed}
  alias ArchLens.Generator.{Architecture, Contexts, Model, Scope}

  defp scope(overrides) do
    defaults = [
      resources: [],
      app_namespace: CtxFixtures.app_namespace(),
      modules: CtxFixtures.healthy_modules(),
      domains: CtxFixtures.domains()
    ]

    struct!(Scope, Keyword.merge(defaults, overrides))
  end

  describe "resolve/1 — folds domains and plain modules into one deterministic list" do
    test "in-place domains and modules resolve, sorted by name; excluded ones drop" do
      %{contexts: contexts} = Contexts.resolve(scope([]))

      assert Enum.map(contexts, & &1.name) == [:accounts, :billing, :custom_name, :ingest, :judge]
      # Telemetry (domain) and Excluded (module) are exclude:true → absent.
      refute :telemetry in Enum.map(contexts, & &1.name)
    end

    test "a domain-backed context carries origin, does_source, and resource membership" do
      accounts = resolve_named(scope([]), :accounts)

      assert accounts.origin == :domain
      assert accounts.provenance == :declared
      assert accounts.does == "users, workspaces, and memberships"
      assert accounts.does_source == :annotation

      assert accounts.resources == [
               "ArchLens.CtxFixtures.Accounts.User",
               "ArchLens.CtxFixtures.Accounts.Workspace"
             ]
    end

    test "a moduledoc-fallback domain is tagged does_source: moduledoc" do
      billing = resolve_named(scope([]), :billing)
      assert billing.origin == :domain
      assert billing.does_source == :moduledoc
    end

    test "a plain context module has origin :context_module and no resources key" do
      judge = resolve_named(scope([]), :judge)
      assert judge.origin == :context_module
      assert judge.does_source == :annotation
      refute Map.has_key?(judge, :resources)

      ingest = resolve_named(scope([]), :ingest)
      assert ingest.does_source == :moduledoc
    end
  end

  describe "resolve/1 — central declarations are deprecated and deduped" do
    test "a central context colliding with an in-place one is dropped, preferring in-place" do
      central = %{contexts: [%{name: :accounts, does: "central copy", modules: "X"}]}

      output =
        capture_io(:stderr, fn ->
          %{contexts: contexts} =
            Contexts.resolve(
              scope(
                domains: [Accounts],
                app_namespace: nil,
                modules: [],
                declared_architecture: central
              )
            )

          send(self(), {:contexts, contexts})
        end)

      assert_received {:contexts, contexts}
      accounts = Enum.find(contexts, &(&1.name == :accounts))
      # Kept the in-place annotation, not the central declaration.
      assert accounts.origin == :domain
      assert output =~ "deprecated"
      assert output =~ "preferring the in-place annotation"
    end

    test "a central-only context is kept but the whole central path warns as deprecated" do
      central = %{contexts: [%{name: :legacy, does: "an old context", modules: "X"}]}

      output =
        capture_io(:stderr, fn ->
          %{contexts: contexts} =
            Contexts.resolve(
              scope(
                domains: [Accounts],
                app_namespace: nil,
                modules: [],
                declared_architecture: central
              )
            )

          send(self(), {:contexts, contexts})
        end)

      assert_received {:contexts, contexts}
      legacy = Enum.find(contexts, &(&1.name == :legacy))
      assert legacy.origin == :central_declared
      assert output =~ "deprecated"
    end
  end

  describe "style_gate/1" do
    test "passes when every folder namespace has a root module" do
      assert Contexts.style_gate(scope([])) == :ok
    end

    test "fails, naming the missing root module, for a folder with no root" do
      modules = CtxFixtures.healthy_modules() ++ [Orphan.Thing]

      assert Contexts.style_gate(scope(modules: modules)) ==
               {:error, {:missing_root_modules, ["ArchLens.CtxFixtures.Orphan"]}}
    end

    test "ignore_namespaces excuses a support directory from the style gate" do
      modules = CtxFixtures.healthy_modules() ++ [Fixtures.Helper]

      assert Contexts.style_gate(scope(modules: modules)) ==
               {:error, {:missing_root_modules, ["ArchLens.CtxFixtures.Fixtures"]}}

      assert Contexts.style_gate(scope(modules: modules, ignore_namespaces: [:fixtures])) == :ok
    end

    test "skips cleanly when the app namespace or module list is unavailable" do
      assert Contexts.style_gate(scope(app_namespace: nil)) == :ok
      assert Contexts.style_gate(scope(modules: [])) == :ok
    end
  end

  describe "annotation_gate/1" do
    test "passes when every domain and root module is described or excluded" do
      assert Contexts.annotation_gate(scope([])) == :ok
    end

    test "fails, naming a domain that carries neither an annotation nor a @moduledoc" do
      domains = CtxFixtures.domains() ++ [Undescribed]

      assert Contexts.annotation_gate(scope(domains: domains)) ==
               {:error, {:undescribed_contexts, ["ArchLens.CtxFixtures.Undescribed"]}}
    end

    test "fails for a plain folder root with no description" do
      modules = CtxFixtures.healthy_modules() ++ [Bare, Bare.Thing]

      assert Contexts.annotation_gate(scope(modules: modules)) ==
               {:error, {:undescribed_contexts, ["ArchLens.CtxFixtures.Bare"]}}
    end
  end

  describe "schema v2 JSON model" do
    test "declared_architecture.contexts serialise with name/does/origin/does_source" do
      json = scope([]) |> Model.to_map() |> Model.encode() |> Jason.decode!()

      assert json["schema_version"] == 2

      contexts = json["declared_architecture"]["contexts"]

      assert Enum.map(contexts, & &1["name"]) == [
               "accounts",
               "billing",
               "custom_name",
               "ingest",
               "judge"
             ]

      accounts = Enum.find(contexts, &(&1["name"] == "accounts"))
      assert accounts["origin"] == "domain"
      assert accounts["does_source"] == "annotation"
      assert accounts["provenance"] == "declared"

      assert accounts["resources"] == [
               "ArchLens.CtxFixtures.Accounts.User",
               "ArchLens.CtxFixtures.Accounts.Workspace"
             ]

      ingest = Enum.find(contexts, &(&1["name"] == "ingest"))
      assert ingest["origin"] == "context_module"
      assert ingest["does_source"] == "moduledoc"
      refute Map.has_key?(ingest, "resources")
    end
  end

  describe "render_artifacts/1 wires both gates" do
    test "a missing root module fails generation with an actionable message" do
      opts = artifact_opts(modules: CtxFixtures.healthy_modules() ++ [Orphan.Thing])

      assert {:error, {:missing_root_modules, ["ArchLens.CtxFixtures.Orphan"]} = reason} =
               Architecture.render_artifacts(opts)

      assert Architecture.format_error(reason) =~ "ignore_namespaces"
    end

    test "an undescribed domain fails generation with an actionable message" do
      opts = artifact_opts(domains: CtxFixtures.domains() ++ [Undescribed])

      assert {:error, {:undescribed_contexts, ["ArchLens.CtxFixtures.Undescribed"]} = reason} =
               Architecture.render_artifacts(opts)

      assert Architecture.format_error(reason) =~ "exclude: true"
    end
  end

  # An explicit, DB-free opts list that renders the fixture app cleanly through the
  # gates (no scanned resources → the privacy gate is vacuous).
  defp artifact_opts(overrides) do
    defaults = [
      scanned_resources: [],
      edges: [],
      oban_workers: [],
      app_namespace: CtxFixtures.app_namespace(),
      modules: CtxFixtures.healthy_modules(),
      domains: CtxFixtures.domains()
    ]

    Keyword.merge(defaults, overrides)
  end

  defp resolve_named(scope, name) do
    %{contexts: contexts} = Contexts.resolve(scope)
    Enum.find(contexts, &(&1.name == name))
  end
end
