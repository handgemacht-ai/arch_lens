defmodule ArchLens.Generator.ContextEdges do
  @moduledoc """
  Aggregates raw cross-module references (`ArchLens.Collect.Dependencies`) into
  cross-context dependency edges, attributing each endpoint to its bounded context
  through the `ArchLens.Generator.Namespace` attributor.

  This is the wave-2 skeleton stub: `build/2` returns `[]`, so `Model.to_map/1`
  folds in an empty `context_dependencies` list and the empty-v3 baseline renders.
  The wave-3 arrows slice fleshes it to map each reference's endpoints through the
  attributor, drop unattributed/self edges, group by `{from_context, to_context}`,
  and emit one deterministic `ctxdep:<from>-><to>` element per group with a
  `reference_count` and a `sample`.
  """

  @doc """
  Cross-context dependency edges for `refs`, attributed through `index`.

  Skeleton stub — always `[]`. Fleshed by the arrows slice.
  """
  @spec build([map()], term()) :: [map()]
  def build(_refs, _index), do: []
end
