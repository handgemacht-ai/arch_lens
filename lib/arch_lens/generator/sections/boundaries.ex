defmodule ArchLens.Generator.Sections.Boundaries do
  @moduledoc """
  Renders the *boundaries* section — the app's declared compile-time zones, read
  from the hex `boundary` library by `ArchLens.Collect.Boundaries`.

  `to_json/1` owns how each boundary element serialises to the JSON model;
  `render/1` owns the Markdown. Both are deterministic: elements are sorted by their
  stable `boundary:<Name>` id and every inner list (deps, exports, dirty xrefs) is
  sorted by the collector, so an unchanged boundary graph reproduces byte-identical
  output.

  Each boundary renders its front door (the boundary module itself), its declared
  boundary deps, its exports split into `sanctioned` (with the verbatim rationale),
  `grandfathered`, and `unclassified` groups, any `dirty_xrefs` the boundary
  compiler recorded, and — only when a boundary has turned a check off — the
  disabled checks. Nothing is inferred: the sanctioned/grandfathered split is the
  app's declared classification, and an export the app has not classified is
  surfaced honestly as `unclassified` rather than guessed into a group.

  `render([])` / `render(nil)` yields `[]`, so an app that does not use `boundary`
  (or has disabled ingestion) renders no section at all.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Boundaries"

  @impl true
  def heading, do: @heading

  @impl true
  def to_json(entries) do
    entries
    |> Enum.map(&Section.jsonable/1)
    |> Enum.sort_by(& &1["id"])
  end

  @impl true
  def render(nil), do: []
  def render([]), do: []

  def render(entries) do
    body =
      entries
      |> Enum.sort_by(& &1["id"])
      |> Enum.flat_map(&boundary_block/1)
      |> drop_trailing_blank()

    [@heading, "", summary_line(entries), "" | body]
  end

  defp boundary_block(entry) do
    ["### #{entry["name"]} (#{entry["type"]})", "" | boundary_lines(entry)] ++ [""]
  end

  defp boundary_lines(entry) do
    exports = entry["exports"] || %{}

    [
      "- Front door: `#{entry["front_door"]}`",
      deps_line(entry["deps"]),
      checks_line(entry["check"]),
      sanctioned_lines(exports["sanctioned"]),
      module_list_line("Grandfathered exports", exports["grandfathered"]),
      module_list_line("Unclassified exports", exports["unclassified"]),
      module_list_line("Dirty cross-references", entry["dirty_xrefs"])
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == nil))
  end

  defp deps_line(deps) when is_list(deps) and deps != [] do
    "- Deps: " <> Enum.map_join(deps, ", ", fn dep -> "`#{dep["module"]}` (#{dep["mode"]})" end)
  end

  defp deps_line(_deps), do: nil

  # Only the notable, surface-relevant case is rendered: a boundary that has turned
  # an inbound or outbound check off. The default (both checks on) is unremarkable
  # and omitted, so it never adds noise to the artifact.
  defp checks_line(%{"in" => in?, "out" => out?}) do
    disabled =
      [{in?, "inbound"}, {out?, "outbound"}]
      |> Enum.reject(fn {enabled?, _label} -> enabled? end)
      |> Enum.map(fn {_enabled?, label} -> label end)

    case disabled do
      [] -> nil
      labels -> "- Checks disabled: #{Enum.join(labels, ", ")}"
    end
  end

  defp checks_line(_check), do: nil

  defp sanctioned_lines(sanctioned) when is_list(sanctioned) and sanctioned != [] do
    ["- Sanctioned exports:" | Enum.map(sanctioned, &"  - `#{&1["module"]}` — #{&1["reason"]}")]
  end

  defp sanctioned_lines(_sanctioned), do: nil

  defp module_list_line(label, modules) when is_list(modules) and modules != [] do
    "- #{label}: " <> Enum.map_join(modules, ", ", &"`#{&1}`")
  end

  defp module_list_line(_label, _modules), do: nil

  defp summary_line(entries) do
    unclassified =
      Enum.count(entries, &(get_in(&1, ["exports", "unclassified"]) not in [nil, []]))

    "_#{length(entries)} #{plural(length(entries), "boundary")} · " <>
      "#{unclassified} with unclassified #{plural(unclassified, "export")}._"
  end

  defp plural(1, word), do: word
  defp plural(_n, "boundary"), do: "boundaries"
  defp plural(_n, word), do: word <> "s"

  defp drop_trailing_blank(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end
end
