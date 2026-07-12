defmodule ArchLens.Generator.FlowsTest do
  # async: false — resolves scopes over the compiled CtxFixtures app, like the
  # context-dependency and namespace tests it shares an index with.
  use ExUnit.Case, async: false

  alias ArchLens.CtxFixtures
  alias ArchLens.CtxFixtures.{Ingest, Judge, Renamed}
  alias ArchLens.Generator.{Document, Flows, Model, Scope}

  @fixture_dir Path.join([__DIR__, "..", "..", "fixtures", "flows"])

  # --- scenario building --------------------------------------------------------

  # The isolated flows scenario: the healthy CtxFixtures context set (judge, ingest,
  # custom_name) with the cross-module references that derive the ctxdep edges
  # judge->ingest, ingest->custom_name, custom_name->judge, one http-boundary edge
  # from the ingest context to Stripe, one collected entry point attributed to the
  # judge context, and a declared Stripe external the flows terminate at.
  defp scenario_refs do
    [
      ref(Judge.Scorer, Ingest.Parser, [
        %{file: "lib/arch_lens/ctx_fixtures/judge/scorer.ex", line: 10}
      ]),
      ref(Ingest.Parser, Renamed.Worker, [
        %{file: "lib/arch_lens/ctx_fixtures/ingest/parser.ex", line: 20}
      ]),
      ref(Renamed.Worker, Judge.Scorer, [
        %{file: "lib/arch_lens/ctx_fixtures/renamed/worker.ex", line: 8}
      ])
    ]
  end

  defp ref(from_module, to_module, call_sites) do
    %{from_module: from_module, to_module: to_module, call_sites: call_sites}
  end

  defp stripe_edge do
    %ArchLens.Edge{
      kind: :http_boundary,
      builder: Ingest.Parser,
      target: "https://api.stripe.com/v1/charges",
      call_sites: [{"lib/arch_lens/ctx_fixtures/ingest/parser.ex", 30}],
      metadata: %{}
    }
  end

  defp score_route do
    %{
      id: "route:POST:/score",
      kind: :api,
      source: :collected,
      method: "POST",
      path: "/score",
      handler: "ArchLens.CtxFixtures.Judge.Scorer",
      pipelines: [],
      basis: "path segment /score"
    }
  end

  defp declared_stripe do
    %{
      name: :stripe,
      via: :http,
      target: "https://api.stripe.com",
      does: "settles the charge",
      evidence_hint: [],
      source: "declared"
    }
  end

  defp step(kind, ref, opts \\ []) do
    %{
      kind: kind,
      ref: ref,
      does: Keyword.get(opts, :does),
      unverified: Keyword.get(opts, :unverified, false)
    }
  end

  defp flow(name, steps, does \\ "a flow") do
    %{name: name, does: does, steps: steps, source: "declared"}
  end

  # The two golden flows: one that proves an entry->context->context->external chain
  # through all three backing kinds, and one that leans on the `unverified` hatch.
  defp golden_flows do
    [
      flow(
        :scoring_pipeline,
        [
          step(:entry_point, "POST /score", does: "receives the copy to score"),
          step(:context, :judge, does: "scores the copy against the brand judges"),
          step(:context, :ingest, does: "normalises the scored payload"),
          step(:external, :stripe, does: "settles the charge")
        ],
        "Scores incoming copy and settles the charge."
      ),
      flow(
        :assert_demo,
        [
          step(:context, :ingest),
          step(:context, :judge, does: "asserted hop", unverified: true)
        ],
        "Demonstrates the unverified escape hatch."
      )
    ]
  end

  defp opts(flows) do
    [
      app: :arch_lens,
      app_namespace: CtxFixtures,
      domains: [],
      scanned_resources: [],
      modules: [Judge, Judge.Scorer, Ingest, Ingest.Parser, Renamed, Renamed.Worker],
      edges: [stripe_edge()],
      oban_workers: [],
      entry_points: [score_route()],
      runtime_components: [],
      external_systems: [],
      declared_architecture: %{externals: [declared_stripe()], flows: flows},
      dependency_refs: scenario_refs(),
      deps: [],
      cron: %{},
      ignore_externals: [],
      decisions: [],
      decision_errors: []
    ]
  end

  defp scope(flows), do: Scope.resolve(opts(flows))
  defp resolve(flows), do: Flows.resolve(scope(flows))
  defp gate(flows), do: Flows.gate(scope(flows))

  defp only_step(flows), do: flows |> resolve() |> hd() |> Map.fetch!(:steps) |> List.last()

  # --- resolve: backing taxonomy ------------------------------------------------

  describe "resolve/1 — backing taxonomy" do
    test "the first step has no inbound backing" do
      [first | _] =
        resolve([flow(:f, [step(:context, :judge), step(:context, :ingest)])]) |> steps()

      assert first == %{kind: "context", ref: "context:judge", backed_by: nil}
    end

    test "a context->context hop is backed by its G1 dependency edge" do
      backed = only_step([flow(:f, [step(:context, :judge), step(:context, :ingest)])])

      assert backed.backed_by == %{type: "dependency_edge", ref: "ctxdep:judge->ingest"}
    end

    test "a context->external hop is backed by its http-boundary edge" do
      backed = only_step([flow(:f, [step(:context, :ingest), step(:external, :stripe)])])

      assert backed.backed_by == %{
               type: "http_boundary",
               ref:
                 "edge:http_boundary:ArchLens.CtxFixtures.Ingest.Parser=>https://api.stripe.com/v1/charges"
             }
    end

    test "an external->context hop is backed by the same http-boundary edge (either direction)" do
      backed = only_step([flow(:f, [step(:external, :stripe), step(:context, :ingest)])])

      assert backed.backed_by.type == "http_boundary"
    end

    test "an entry_point->context hop is backed by its G2 entry binding" do
      backed =
        only_step([flow(:f, [step(:entry_point, "POST /score"), step(:context, :judge)])])

      assert backed.backed_by == %{type: "entry_binding", ref: "route:POST:/score"}
    end

    test "an unproven hop marked unverified records the visible asserted escape hatch" do
      # ingest->judge is not a derived dependency edge, so this hop must be asserted.
      backed =
        only_step([flow(:f, [step(:context, :ingest), step(:context, :judge, unverified: true)])])

      assert backed.backed_by == %{type: "asserted"}
    end

    test "a proven hop records the proof even when it is also marked unverified" do
      # judge->ingest IS a real edge; the proof wins over the assertion.
      backed =
        only_step([flow(:f, [step(:context, :judge), step(:context, :ingest, unverified: true)])])

      assert backed.backed_by == %{type: "dependency_edge", ref: "ctxdep:judge->ingest"}
    end
  end

  # --- resolve: shape + determinism ---------------------------------------------

  describe "resolve/1 — shape and determinism" do
    test "each step canonicalises its ref and carries its verbatim does" do
      [entry, judge, ingest, stripe] = only_flow_steps(golden_flows(), :scoring_pipeline)

      assert entry.kind == "entry_point"
      assert entry.ref == "route:POST:/score"
      assert entry.does == "receives the copy to score"

      assert {judge.kind, judge.ref} == {"context", "context:judge"}
      assert {ingest.kind, ingest.ref} == {"context", "context:ingest"}
      assert {stripe.kind, stripe.ref} == {"external", "external:stripe"}
    end

    test "a step without a does omits the key entirely" do
      [ingest, _judge] = only_flow_steps(golden_flows(), :assert_demo)

      refute Map.has_key?(ingest, :does)
    end

    test "flows are sorted by name while steps keep declaration order" do
      resolved = resolve(golden_flows())

      assert Enum.map(resolved, & &1.name) == ["assert_demo", "scoring_pipeline"]

      assert only_flow_steps(golden_flows(), :scoring_pipeline) |> Enum.map(& &1.kind) ==
               ["entry_point", "context", "context", "external"]
    end

    test "a flow carries its id, verbatim does, and declared source" do
      scoring = resolve(golden_flows()) |> Enum.find(&(&1.name == "scoring_pipeline"))

      assert scoring.id == "flow:scoring_pipeline"
      assert scoring.does == "Scores incoming copy and settles the charge."
      assert scoring.source == "declared"
    end

    test "no declared flows yields an empty list" do
      assert resolve([]) == []
    end

    test "generating twice from the same scenario is identical" do
      assert resolve(golden_flows()) == resolve(golden_flows())
    end
  end

  # --- gate ---------------------------------------------------------------------

  describe "gate/1 — hop existence" do
    test "valid flows pass" do
      assert gate(golden_flows()) == :ok
    end

    test "a context ref naming nothing real is an offender" do
      assert {:error, {:invalid_flows, offenders}} =
               gate([flow(:f, [step(:context, :nonexistent)])])

      assert Enum.any?(offenders, &(&1 =~ "flow :f" and &1 =~ ":nonexistent"))
    end

    test "an entry_point ref naming no collected route is an offender" do
      assert {:error, {:invalid_flows, offenders}} =
               gate([flow(:f, [step(:entry_point, "GET /missing")])])

      assert Enum.any?(offenders, &(&1 =~ "entry_point" and &1 =~ "GET /missing"))
    end

    test "an external ref naming no known external is an offender" do
      assert {:error, {:invalid_flows, offenders}} =
               gate([flow(:f, [step(:external, :unknown_vendor)])])

      assert Enum.any?(offenders, &(&1 =~ "external" and &1 =~ ":unknown_vendor"))
    end
  end

  describe "gate/1 — adjacency backing" do
    test "an unbacked adjacency without the escape hatch is an offender" do
      # ingest->judge is not a derived dependency edge and is not marked unverified.
      assert {:error, {:invalid_flows, offenders}} =
               gate([flow(:f, [step(:context, :ingest), step(:context, :judge)])])

      assert Enum.any?(offenders, &(&1 =~ "adjacency" and &1 =~ "step 2"))
    end

    test "the same adjacency passes once the later step is marked unverified" do
      assert gate([flow(:f, [step(:context, :ingest), step(:context, :judge, unverified: true)])]) ==
               :ok
    end

    test "a proven adjacency passes without the escape hatch" do
      assert gate([flow(:f, [step(:context, :judge), step(:context, :ingest)])]) == :ok
    end
  end

  # --- section renderer ---------------------------------------------------------

  describe "Data flows Markdown section" do
    test "renders each flow, its verbatim does, and terse structured backing" do
      md = golden_flows() |> render_scope() |> Document.render()

      assert md =~ "## Data flows"
      assert md =~ "### scoring_pipeline"
      assert md =~ "_Scores incoming copy and settles the charge._"

      assert md =~ "1. **entry point** `POST /score` — receives the copy to score"

      assert md =~
               "2. **context** `judge` — scores the copy against the brand judges ← entry binding `route:POST:/score`"

      assert md =~
               "3. **context** `ingest` — normalises the scored payload ← dependency edge `ctxdep:judge->ingest`"

      assert md =~ "← http boundary `edge:http_boundary:"
    end

    test "the asserted escape hatch renders visibly" do
      md = golden_flows() |> render_scope() |> Document.render()

      assert md =~ "### assert_demo"
      assert md =~ "2. **context** `judge` — asserted hop ← _asserted_"
    end

    test "no flows renders no section" do
      md = [] |> render_scope() |> Document.render()

      refute md =~ "## Data flows"
    end
  end

  # --- golden contract ----------------------------------------------------------

  describe "golden contract scenario" do
    test "the full v3 model renders byte-identically to the committed JSON fixture" do
      json = Model.to_json(scope(golden_flows()))
      assert json == File.read!(Path.join(@fixture_dir, "architecture.gen.json"))
    end

    test "the model is byte-identical across two runs" do
      assert Model.to_json(scope(golden_flows())) == Model.to_json(scope(golden_flows()))
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp steps(resolved_flows), do: resolved_flows |> hd() |> Map.fetch!(:steps)

  defp only_flow_steps(flows, name) do
    flows |> resolve() |> Enum.find(&(&1.name == to_string(name))) |> Map.fetch!(:steps)
  end

  defp render_scope(flows), do: flows |> scope() |> Model.to_map()
end
