defmodule ArchLens.Collect.Dependencies do
  @moduledoc """
  Collects raw cross-module call references (the source of the G1 cross-context
  dependency edges).

  This is the wave-2 skeleton stub: it returns `[]` so an empty-v3 baseline
  compiles and renders. The wave-3 arrows slice fleshes `collect/1` to build a
  private OTP `:xref` call graph over the app's own compiled BEAMs and return a
  deterministic, sorted list of raw references
  `[%{from_module, to_module, call_sites: [%{file, line}]}]`, intersecting both
  endpoints with the lib-only module set so the edge set is byte-identical across
  `MIX_ENV`.
  """

  @doc """
  Raw cross-module call references for the app.

  Skeleton stub — always `[]`. Fleshed by the arrows slice.
  """
  @spec collect(keyword()) :: [map()]
  def collect(_opts \\ []), do: []
end
