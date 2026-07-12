defmodule ArchLens.Generator.Sections.Decisions do
  @moduledoc """
  Renders the *decisions* section: the architecture-decision records indexed by
  `ArchLens.Collect.Decisions`.

  This is the wave-2 skeleton stub: it renders the empty state and a generic
  bullet, so the empty-v3 baseline renders. The wave-3 decisions slice fleshes
  `render/1` into `- **ADR-NNNN** <title> — _status_ (date) \\`path\\`` bullets and
  `to_json/1` sorted by number.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Decisions"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
