defmodule ArchLens.Generator.Sections.DataInventory do
  @moduledoc """
  Renders the *data inventory* section: the derived context → resources →
  categories view built by `ArchLens.Generator.Model.data_inventory/1`.

  The join introduces no new source of truth — every context name, posture, and
  category string is verbatim from a resource's own privacy declaration or its
  domain/context annotation. This module only shapes that pre-joined list into a
  `## Data inventory` heading with one `### <context>` sub-section per context,
  each a `| Resource | Categories |` table (contexts and resources arrive already
  sorted from the model, and that order is preserved).

  Every posture stays visible in the artifact rather than being silently dropped:
  a `declared` resource lists its categories, a `no_personal_data` resource renders
  `_no personal data_`, an exempt resource `_exempt_`, and an undeclared resource
  `_undeclared_` — so the `privacy_exempt` and `no_personal_data` escape hatches
  are legible in the rendered inventory (principle 2). Empty in, empty out: no
  section renders while the inventory is empty.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Data inventory"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []

  def render(entries) do
    body =
      entries
      |> Enum.map(&context_block/1)
      |> Enum.intersperse([""])
      |> List.flatten()

    [@heading, "" | body]
  end

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)

  defp context_block(%{context: context, resources: resources}) do
    [
      "### #{context}",
      "",
      "| Resource | Categories |",
      "| --- | --- |"
      | Enum.map(resources, &resource_row/1)
    ]
  end

  defp resource_row(%{module: module, posture: posture, categories: categories}) do
    "| `#{module}` | #{categories_cell(posture, categories)} |"
  end

  defp categories_cell("declared", [_ | _] = categories),
    do: "`#{Enum.join(categories, ", ")}`"

  defp categories_cell("no_personal_data", _categories), do: "_no personal data_"
  defp categories_cell("exempt", _categories), do: "_exempt_"
  defp categories_cell("undeclared", _categories), do: "_undeclared_"

  # Fallback for any unexpected posture (or a declared posture with no categories):
  # render the posture verbatim, never fabricating a category.
  defp categories_cell(posture, _categories), do: "_#{posture}_"
end
