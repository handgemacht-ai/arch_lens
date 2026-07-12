defmodule ArchLens.Generator.Sections.DataFlows do
  @moduledoc """
  Renders the *data flows* section: the named, ordered flow stories resolved by
  `ArchLens.Generator.Flows`.

  This is the wave-2 skeleton stub: it renders the empty state and a generic
  bullet, so the empty-v3 baseline renders. The wave-4 flows slice fleshes
  `render/1` to render each flow as `### <name>`, its verbatim `_does_` line, and
  the ordered steps with their `backed_by` suffixes.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Data flows"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
