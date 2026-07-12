defmodule ArchLens.Generator.Sections.DataInventory do
  @moduledoc """
  Renders the *data inventory* section: the derived context → resources →
  categories view built by `ArchLens.Generator.Model.data_inventory/1`.

  This is the wave-2 skeleton stub: it renders the empty state and a generic
  bullet, so the empty-v3 baseline renders. The wave-3 privacy slice fleshes
  `render/1` into a `### <context>` sub-section per context with a
  `| Resource | Categories |` table. The join itself is owned by the model, so
  the JSON `data_inventory` list is already populated; this seam only adds the
  Markdown view.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Data inventory"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
