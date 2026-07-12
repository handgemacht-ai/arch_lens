defmodule ArchLens.Generator.Flows do
  @moduledoc """
  Resolves and validates the declared data-flow stories against the fully-built
  `ArchLens.Generator.Scope`.

  A flow is a named, ordered sequence of hops (entry point → context → external)
  carried raw on `Scope.declared_architecture.flows` by the `ArchLens.System` DSL.
  `resolve/1` turns each flow into a top-level `flows` element: it canonicalises
  every step's `ref` to a stable id (`route:METHOD:/path` | `context:<name>` |
  `external:<slug>`), preserves declaration order, and records for each consecutive
  pair the proof that the transition is real — so a narrative cannot claim a hop the
  code does not have.

  ## Backing taxonomy

  The first step has `backed_by: null` (nothing precedes it). Every later step's
  `backed_by` proves the adjacency to the step before it, drawn from one closed set:

    * **context → context** — a G1 derived dependency edge `A → B`
      (`{"type": "dependency_edge", "ref": "ctxdep:A->B"}`).
    * **context ↔ external** — a collected `:http_boundary` edge whose builder module
      belongs to the context and whose target resolves to the external
      (`{"type": "http_boundary", "ref": "edge:http_boundary:…"}`).
    * **entry point ↔ context** — a G2 authoritative entry-point → context binding
      (`{"type": "entry_binding", "ref": "route:…"}`).

  When the applicable proof cannot be found, the step is an offender **unless** it
  carries `unverified: true`, which records the escape hatch
  `{"type": "asserted"}` — explicit and visible in both artifacts.

  ## Gates

  `gate/1` enforces two layers and returns `:ok` or
  `{:error, {:invalid_flows, offenders}}`:

    1. **hop existence** — every step's `ref` must resolve to a real entry point,
       context, or external. There is no escape hatch; a non-existent element is
       never silently rendered.
    2. **adjacency backing** — every consecutive pair must be proven by the taxonomy
       above, or the later step must be marked `unverified: true`.

  There is deliberately **no completeness gate**: "all flows" is unbounded, so only
  the validity of a declared flow is enforced, never coverage.
  """

  alias ArchLens.Collect.Externals
  alias ArchLens.Edge
  alias ArchLens.Generator.{Attribution, ContextEdges, Contexts, Namespace, Scope}
  alias ArchLens.System.ExternalMerge

  @doc """
  The resolved top-level `flows` list for `scope`, sorted by name.

  Each step carries its canonical `ref`, its verbatim `does` (omitted when absent),
  and a `backed_by` proof (`null` for the first step). Assumes `gate/1` has passed —
  it renders the escape-hatch assertion for an `unverified` hop but does not itself
  reject an unbacked one.
  """
  @spec resolve(Scope.t()) :: [map()]
  def resolve(%Scope{} = scope) do
    ctx = build_context(scope)

    scope
    |> declared_flows()
    |> Enum.map(&resolve_flow(&1, ctx))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The flow-validity gate: `:ok`, or `{:error, {:invalid_flows, offenders}}`.

  `offenders` is a deterministic list of human-readable strings, each naming the
  flow and step that failed hop existence or adjacency backing.
  """
  @spec gate(Scope.t()) :: :ok | {:error, {:invalid_flows, [String.t()]}}
  def gate(%Scope{} = scope) do
    ctx = build_context(scope)

    offenders =
      scope
      |> declared_flows()
      |> Enum.flat_map(&flow_offenders(&1, ctx))

    case offenders do
      [] -> :ok
      offenders -> {:error, {:invalid_flows, offenders}}
    end
  end

  # --- resolution ---------------------------------------------------------------

  defp resolve_flow(flow, ctx) do
    steps = flow_steps(flow)
    resolved = steps |> pairs() |> Enum.map(fn {prev, step} -> resolve_step(prev, step, ctx) end)

    %{
      id: "flow:" <> to_string(flow_name(flow)),
      name: to_string(flow_name(flow)),
      does: flow_does(flow),
      source: "declared",
      steps: resolved
    }
  end

  defp resolve_step(prev, step, ctx) do
    %{kind: to_string(step[:kind]), ref: canonical_ref(step[:kind], step[:ref])}
    |> maybe_put(:does, step[:does])
    |> Map.put(:backed_by, backed_by(prev, step, ctx))
  end

  # The first step (no predecessor) has no inbound adjacency; a proven pair records
  # its proof; an unproven pair records the `unverified` assertion. An unproven,
  # non-asserted pair only reaches here when the gate was bypassed — it records no
  # backing rather than fabricating an assertion the author did not make.
  defp backed_by(nil, _step, _ctx), do: nil

  defp backed_by(prev, step, ctx) do
    case prove(prev, step, ctx) do
      {:ok, proof} -> proof
      :unproven -> if step[:unverified], do: %{type: "asserted"}, else: nil
    end
  end

  # --- gate ---------------------------------------------------------------------

  defp flow_offenders(flow, ctx) do
    steps = flow_steps(flow)
    name = flow_name(flow)

    existence_offenders(name, steps, ctx) ++ adjacency_offenders(name, steps, ctx)
  end

  defp existence_offenders(name, steps, ctx) do
    steps
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {step, n} ->
      if hop_exists?(step, ctx), do: [], else: [existence_offender(name, n, step)]
    end)
  end

  defp adjacency_offenders(name, steps, ctx) do
    steps
    |> pairs()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {{nil, _step}, _n} -> []
      {{prev, step}, n} -> pair_offender(name, n, prev, step, ctx)
    end)
  end

  defp pair_offender(name, n, prev, step, ctx) do
    case prove(prev, step, ctx) do
      {:ok, _proof} -> []
      :unproven -> if step[:unverified], do: [], else: [adjacency_offender(name, n, step)]
    end
  end

  defp hop_exists?(%{kind: :entry_point, ref: ref}, ctx),
    do: MapSet.member?(ctx.entry_ids, canonical_ref(:entry_point, ref))

  defp hop_exists?(%{kind: :context, ref: ref}, ctx),
    do: MapSet.member?(ctx.context_names, to_string(ref))

  defp hop_exists?(%{kind: :external, ref: ref}, ctx),
    do: MapSet.member?(ctx.external_ids, canonical_ref(:external, ref))

  defp existence_offender(name, n, step) do
    "flow :#{name} step #{n} (#{step[:kind]} #{inspect(step[:ref])}): " <>
      "references no known #{step[:kind]}"
  end

  defp adjacency_offender(name, n, step) do
    "flow :#{name} step #{n} (#{step[:kind]} #{inspect(step[:ref])}): " <>
      "adjacency to the previous step is unproven; mark it `unverified: true` to assert it"
  end

  # --- adjacency proofs ---------------------------------------------------------

  defp prove(prev, step, ctx) do
    case {prev[:kind], step[:kind]} do
      {:context, :context} -> prove_dependency(prev, step, ctx)
      {:context, :external} -> prove_boundary(prev, step, ctx)
      {:external, :context} -> prove_boundary(step, prev, ctx)
      {:entry_point, :context} -> prove_entry(prev, step, ctx)
      {:context, :entry_point} -> prove_entry(step, prev, ctx)
      _ -> :unproven
    end
  end

  defp prove_dependency(from_step, to_step, ctx) do
    from = to_string(from_step[:ref])
    to = to_string(to_step[:ref])

    case Map.get(ctx.ctxdep_ids, {from, to}) do
      nil -> :unproven
      id -> {:ok, %{type: "dependency_edge", ref: id}}
    end
  end

  defp prove_boundary(context_step, external_step, ctx) do
    context = to_string(context_step[:ref])
    external_id = canonical_ref(:external, external_step[:ref])

    case Enum.find(ctx.boundaries, &(&1.context == context and &1.external_id == external_id)) do
      %{edge_id: edge_id} -> {:ok, %{type: "http_boundary", ref: edge_id}}
      nil -> :unproven
    end
  end

  defp prove_entry(entry_step, context_step, ctx) do
    route_id = canonical_ref(:entry_point, entry_step[:ref])
    context = to_string(context_step[:ref])

    if Map.get(ctx.entry_context, route_id) == context do
      {:ok, %{type: "entry_binding", ref: route_id}}
    else
      :unproven
    end
  end

  # --- resolved-scope context ---------------------------------------------------

  # Everything the resolver and gate join against, computed once from the scope: the
  # attributed entry points, the resolved context names, the G1 dependency edges, the
  # merged externals, and the http-boundary edges keyed by their builder's context.
  defp build_context(%Scope{} = scope) do
    %{contexts: contexts} = Contexts.resolve(scope)
    index = Namespace.context_index(scope, contexts)
    membership = Namespace.membership(index)
    entries = Attribution.attribute(scope.entry_points, contexts)

    %{
      entry_ids: entries |> Enum.map(& &1[:id]) |> Enum.reject(&is_nil/1) |> MapSet.new(),
      entry_context: entry_context(entries),
      context_names: MapSet.new(contexts, &to_string(&1.name)),
      ctxdep_ids: ctxdep_ids(scope, index),
      external_ids: scope |> merged_externals() |> MapSet.new(& &1.id),
      boundaries: http_boundaries(scope.edges, membership)
    }
  end

  defp entry_context(entries) do
    for entry <- entries, id = entry[:id], not is_nil(id), into: %{}, do: {id, entry[:context]}
  end

  defp ctxdep_ids(scope, index) do
    scope.dependency_refs
    |> ContextEdges.build(index)
    |> Map.new(&{{&1.from, &1.to}, &1.id})
  end

  defp merged_externals(%Scope{} = scope) do
    ExternalMerge.merge(
      scope.external_systems,
      declared_externals(scope.declared_architecture),
      ignore_externals: scope.ignore_externals,
      deps: scope.deps
    )
  end

  defp declared_externals(%{externals: externals}) when is_list(externals), do: externals
  defp declared_externals(_declared), do: []

  # Every `:http_boundary` edge whose builder module attributes to a context, keyed
  # to that context and to the external its target resolves to (the same canonical
  # `external:<slug>` id `ArchLens.Collect.Externals` derives).
  defp http_boundaries(edges, membership) do
    edges
    |> Enum.filter(&(&1.kind == :http_boundary))
    |> Enum.flat_map(&boundary_entry(&1, membership))
  end

  defp boundary_entry(edge, membership) do
    with module when is_atom(module) and not is_nil(module) <- builder_module(edge.builder),
         context when not is_nil(context) <- Map.get(membership, module),
         external_id when is_binary(external_id) <- boundary_external_id(edge) do
      [%{context: to_string(context), external_id: external_id, edge_id: Edge.id(edge)}]
    else
      _ -> []
    end
  end

  defp boundary_external_id(edge) do
    case Externals.boundary_vendors(edges: [edge]) do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp builder_module({module, _fun, _arity}), do: module
  defp builder_module({module, _name}), do: module
  defp builder_module(module) when is_atom(module), do: module
  defp builder_module(_builder), do: nil

  # --- canonicalisation ---------------------------------------------------------

  defp canonical_ref(:entry_point, ref) when is_binary(ref) do
    case String.split(ref, " ", parts: 2) do
      [method, path] -> "route:" <> String.upcase(method) <> ":" <> path
      _ -> "route:" <> ref
    end
  end

  defp canonical_ref(:entry_point, ref), do: "route:" <> to_string(ref)
  defp canonical_ref(:context, ref), do: "context:" <> to_string(ref)
  defp canonical_ref(:external, ref), do: "external:" <> slug(to_string(ref))

  # Mirrors `ArchLens.System.ExternalMerge` / `ArchLens.Collect.Externals` so a
  # step's `external :name` resolves to the same stable id the merged externals use.
  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # --- flow accessors -----------------------------------------------------------

  defp declared_flows(%Scope{declared_architecture: %{flows: flows}}) when is_list(flows),
    do: flows

  defp declared_flows(_scope), do: []

  defp flow_steps(flow), do: Map.get(flow, :steps, [])
  defp flow_name(flow), do: Map.get(flow, :name)
  defp flow_does(flow), do: Map.get(flow, :does)

  # The steps paired with their predecessor: `{nil, first}`, then `{prev, step}`.
  defp pairs(steps) do
    Enum.zip([nil | steps], steps)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
