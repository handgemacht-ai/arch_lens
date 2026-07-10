defmodule ArchLens.Generator.Sections.EntryPoints do
  @moduledoc """
  Seam for the *entry points* slice (HTTP routes, mounted endpoints, mailboxes).

  The generator carries `Scope.entry_points` end-to-end already: this module owns
  how those entries render to Markdown (`render/1`) and serialise to the JSON model
  (`to_json/1`). It is a **stub**: the entry-points slice fills both in and
  populates `Scope.entry_points` from a host-app wrapper task, touching only this
  file plus its own collector/task. Empty in, empty out — no section renders while
  the field is empty.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Entry points"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
