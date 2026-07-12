defmodule ArchLens.Generator.ContextEdgesTest do
  # async: false — resolves scopes over the compiled CtxFixtures app, like the
  # namespace tests it shares an index with.
  use ExUnit.Case, async: false

  alias ArchLens.CtxFixtures
  alias ArchLens.CtxFixtures.{Accounts, Excluded, Ingest, Judge, Renamed}
  alias ArchLens.Generator.{ContextEdges, Contexts, Document, Model, Namespace, Scope}

  @fixture_dir Path.join([__DIR__, "..", "..", "fixtures", "context_dependencies"])

  defp index do
    scope =
      struct!(Scope,
        resources: [],
        app_namespace: CtxFixtures.app_namespace(),
        modules: CtxFixtures.healthy_modules(),
        domains: CtxFixtures.domains()
      )

    Namespace.context_index(scope, Contexts.resolve(scope).contexts)
  end

  defp ref(from_module, to_module, call_sites) do
    %{from_module: from_module, to_module: to_module, call_sites: call_sites}
  end

  defp build(refs), do: ContextEdges.build(refs, index())

  describe "attribution" do
    test "a cross-context reference becomes one context->context edge" do
      assert [edge] = build([ref(Judge.Scorer, Ingest.Parser, [%{file: "a.ex", line: 1}])])

      assert edge == %{
               id: "ctxdep:judge->ingest",
               kind: "context_dependency",
               source: "collected",
               from: "judge",
               to: "ingest",
               reference_count: 1,
               sample: %{
                 from_module: "ArchLens.CtxFixtures.Judge.Scorer",
                 to_module: "ArchLens.CtxFixtures.Ingest.Parser",
                 file: "a.ex",
                 line: 1
               }
             }
    end

    test "a within-context reference (same context, different modules) is dropped" do
      assert build([ref(Accounts.User, Accounts.Workspace, [%{file: "a.ex", line: 1}])]) == []
    end

    test "a module self-reference is dropped" do
      assert build([ref(Judge.Scorer, Judge.Scorer, [%{file: "a.ex", line: 1}])]) == []
    end

    test "a reference whose source is unattributed is dropped" do
      assert build([ref(Enum, Judge.Scorer, [%{file: "a.ex", line: 1}])]) == []
    end

    test "a reference whose target is unattributed is dropped" do
      assert build([ref(Judge.Scorer, Enum, [%{file: "a.ex", line: 1}])]) == []
    end

    test "a reference into an excluded context is dropped" do
      assert build([ref(Judge.Scorer, Excluded.Helper, [%{file: "a.ex", line: 1}])]) == []
    end
  end

  describe "reference_count" do
    test "counts distinct caller modules in the source context" do
      refs = [
        ref(Judge, Ingest.Parser, [%{file: "a.ex", line: 1}]),
        ref(Judge.Scorer, Ingest.Parser, [%{file: "b.ex", line: 2}]),
        # Judge again, a different target module in the same context — counted once.
        ref(Judge, Ingest, [%{file: "c.ex", line: 3}])
      ]

      assert [%{from: "judge", to: "ingest", reference_count: 2}] = build(refs)
    end
  end

  describe "sample" do
    test "picks the minimum {from_module, to_module, file, line} across the group" do
      refs = [
        ref(Judge.Scorer, Ingest.Parser, [%{file: "b.ex", line: 2}]),
        ref(Judge, Ingest.Parser, [%{file: "a.ex", line: 9}])
      ]

      # "…Judge" sorts before "…Judge.Scorer", so the Judge call site wins.
      assert [%{sample: sample}] = build(refs)

      assert sample == %{
               from_module: "ArchLens.CtxFixtures.Judge",
               to_module: "ArchLens.CtxFixtures.Ingest.Parser",
               file: "a.ex",
               line: 9
             }
    end

    test "the minimum line within the chosen call site is taken" do
      assert [%{sample: %{line: 20}}] =
               build([
                 ref(Ingest.Parser, Renamed.Worker, [
                   %{file: "a.ex", line: 42},
                   %{file: "a.ex", line: 20}
                 ])
               ])
    end

    test "omits line when the chosen call site has none" do
      assert [%{sample: sample}] = build([ref(Renamed.Worker, Judge.Scorer, [%{file: "a.ex"}])])

      refute Map.has_key?(sample, :line)

      assert sample == %{
               from_module: "ArchLens.CtxFixtures.Renamed.Worker",
               to_module: "ArchLens.CtxFixtures.Judge.Scorer",
               file: "a.ex"
             }
    end

    test "prefers a lined call site over a lineless one at the same endpoints" do
      assert [%{sample: %{line: 3}}] =
               build([ref(Judge, Ingest.Parser, [%{file: "a.ex"}, %{file: "a.ex", line: 3}])])
    end
  end

  describe "ordering and determinism" do
    test "edges are sorted by id" do
      refs = [
        ref(Judge.Scorer, Ingest.Parser, [%{file: "a.ex", line: 1}]),
        ref(Renamed.Worker, Judge.Scorer, [%{file: "b.ex", line: 2}]),
        ref(Ingest.Parser, Renamed.Worker, [%{file: "c.ex", line: 3}])
      ]

      assert Enum.map(build(refs), & &1.id) == [
               "ctxdep:custom_name->judge",
               "ctxdep:ingest->custom_name",
               "ctxdep:judge->ingest"
             ]
    end

    test "output is independent of input order" do
      refs = [
        ref(Judge.Scorer, Ingest.Parser, [%{file: "a.ex", line: 1}]),
        ref(Renamed.Worker, Judge.Scorer, [%{file: "b.ex", line: 2}]),
        ref(Ingest.Parser, Renamed.Worker, [%{file: "c.ex", line: 3}])
      ]

      assert build(refs) == build(Enum.reverse(refs))
    end

    test "no refs yields no edges" do
      assert build([]) == []
    end
  end

  # --- golden contract scenario ------------------------------------------------

  # The isolated context-dependencies scenario: a healthy CtxFixtures module set with
  # injected cross-module references that exercise a no-line sample, a multi-call-site
  # minimum, a reference_count of two, and the self-context / unattributed drops.
  defp scenario_refs do
    [
      ref(Judge.Scorer, Ingest.Parser, [
        %{file: "lib/arch_lens/ctx_fixtures/judge/scorer.ex", line: 10}
      ]),
      ref(Judge, Ingest.Parser, [%{file: "lib/arch_lens/ctx_fixtures/judge.ex", line: 5}]),
      ref(Ingest.Parser, Renamed.Worker, [
        %{file: "lib/arch_lens/ctx_fixtures/ingest/parser.ex", line: 20},
        %{file: "lib/arch_lens/ctx_fixtures/ingest/parser.ex", line: 42}
      ]),
      ref(Renamed.Worker, Judge.Scorer, [%{file: "lib/arch_lens/ctx_fixtures/renamed/worker.ex"}]),
      # Dropped: a within-context (judge->judge) and an unattributed (->Enum) reference.
      ref(Judge.Scorer, Judge, [%{file: "lib/arch_lens/ctx_fixtures/judge/scorer.ex", line: 12}]),
      ref(Judge.Scorer, Enum, [%{file: "lib/arch_lens/ctx_fixtures/judge/scorer.ex", line: 99}])
    ]
  end

  defp scenario_opts do
    [
      app: :arch_lens,
      app_namespace: CtxFixtures,
      domains: [],
      scanned_resources: [],
      modules: [
        Judge,
        Judge.Scorer,
        Ingest,
        Ingest.Parser,
        Renamed,
        Renamed.Worker
      ],
      edges: [],
      oban_workers: [],
      entry_points: [],
      runtime_components: [],
      external_systems: [],
      declared_architecture: [],
      dependency_refs: scenario_refs(),
      deps: [],
      cron: %{},
      ignore_externals: [],
      decisions: [],
      decision_errors: []
    ]
  end

  describe "golden contract scenario" do
    test "the full v3 model renders byte-identically to the committed JSON fixture" do
      json = Model.to_json(Scope.resolve(scenario_opts()))
      assert json == File.read!(Path.join(@fixture_dir, "architecture.gen.json"))
    end

    test "generating twice from the same scenario is byte-identical" do
      assert Model.to_json(Scope.resolve(scenario_opts())) ==
               Model.to_json(Scope.resolve(scenario_opts()))
    end

    test "the Markdown section quotes the reference count and a sample call site" do
      md = scenario_opts() |> Scope.resolve() |> Model.to_map() |> Document.render()

      assert md =~ "## Context dependencies"

      assert md =~
               "- `judge` → `ingest` (2 referencing modules; e.g. `ArchLens.CtxFixtures.Judge` → `ArchLens.CtxFixtures.Ingest.Parser` at lib/arch_lens/ctx_fixtures/judge.ex:5)"

      # A sample with no resolved line renders the file only, no trailing colon.
      assert md =~
               "- `custom_name` → `judge` (1 referencing module; e.g. `ArchLens.CtxFixtures.Renamed.Worker` → `ArchLens.CtxFixtures.Judge.Scorer` at lib/arch_lens/ctx_fixtures/renamed/worker.ex)"
    end
  end
end
