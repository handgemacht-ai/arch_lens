defmodule ArchLens.Collect.Decisions do
  @moduledoc """
  Indexes the architecture-decision records (ADRs) under the configured decisions
  directory into deterministic, verbatim-front-matter elements.

  This is the wave-2 skeleton stub: `scan/1` reads nothing and returns
  `%{decisions: [], errors: []}`, so the empty-v3 baseline renders and the
  decisions validity gate passes. The wave-3 decisions slice fleshes it to read
  each `NNNN-slug.md`, parse its closed-grammar front-matter (`title`, `status`,
  `date`), and return the sorted decision elements plus any per-file parse errors
  for the gate.
  """

  @doc """
  Scan the decisions directory into `%{decisions: [...], errors: [...]}`.

  Skeleton stub — always `%{decisions: [], errors: []}`. Fleshed by the decisions
  slice.
  """
  @spec scan(String.t() | nil) :: %{decisions: [map()], errors: [{String.t(), String.t()}]}
  def scan(_dir \\ nil), do: %{decisions: [], errors: []}
end
