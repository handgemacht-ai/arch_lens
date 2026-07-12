defmodule ArchLens.Generator.Sections.ContextDependencies do
  @moduledoc """
  Renders the *context dependencies* section: the cross-context dependency edges
  aggregated by `ArchLens.Generator.ContextEdges` from collected call references.

  This is the wave-2 skeleton stub: it renders the empty state and a generic
  bullet, so the empty-v3 baseline renders. The wave-3 arrows slice fleshes
  `render/1` to show `from → to (N referencing modules; e.g. …)` and `to_json/1`.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Context dependencies"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
