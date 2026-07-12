defmodule ArchLens.Generator.Attribution do
  @moduledoc """
  Attributes each entry point to its bounded context, stamping `context` and
  `context_basis` on every entry-point element.

  This is the wave-2 skeleton stub: `attribute/2` passes the entry points through
  unchanged (no `context`/`context_basis` stamped), so the empty-v3 baseline
  renders. The wave-3 entry-points slice fleshes it to stamp the attributed
  context — via a context's declared handler `interface`, else namespace
  containment, else `null` (rendered "Unattributed", never guessed).
  """

  @doc """
  Stamp `context`/`context_basis` on each entry point in `entry_points`.

  Skeleton stub — returns `entry_points` unchanged. Fleshed by the entry-points
  slice.
  """
  @spec attribute([map()], [map()]) :: [map()]
  def attribute(entry_points, _contexts), do: entry_points
end
