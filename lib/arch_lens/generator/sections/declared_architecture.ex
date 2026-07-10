defmodule ArchLens.Generator.Sections.DeclaredArchitecture do
  @moduledoc """
  Seam for the *declared architecture* slice: the architecture a team asserts
  (allowed edges, forbidden dependencies, layering), validated against what the
  generator actually collected — the declared-vs-collected gate, one rung above
  `ArchLens.Generator.Retention`.

  A stub the declared-architecture slice fills in: it owns Markdown (`render/1`)
  and JSON (`to_json/1`) for `Scope.declared_architecture`, plus the host-app
  wrapper that populates the field. Empty while unpopulated, so no section renders
  yet. Entries carry `source: "declared"` when serialised, distinct from the
  `collected` edges they are checked against.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Declared architecture"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries) do
    Enum.map(entries, fn entry ->
      entry
      |> Section.jsonable()
      |> put_source()
    end)
  end

  defp put_source(entry) when is_map(entry), do: Map.put_new(entry, "source", "declared")
  defp put_source(entry), do: entry
end
