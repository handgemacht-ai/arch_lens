defmodule ArchLens.Generator.Sections.RuntimeComponents do
  @moduledoc """
  Seam for the *runtime components* slice (supervised processes: GenServers,
  supervisors, registries, PubSub, long-running workers).

  A stub the runtime-components slice fills in: it owns Markdown (`render/1`) and
  JSON (`to_json/1`) for `Scope.runtime_components`, plus the host-app wrapper that
  populates the field. Empty while unpopulated, so no section renders yet.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Runtime components"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
