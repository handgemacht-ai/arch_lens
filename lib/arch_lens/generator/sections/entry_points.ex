defmodule ArchLens.Generator.Sections.EntryPoints do
  @moduledoc """
  Renders the *entry points* seam (HTTP routes / mounted endpoints).

  `ArchLens.Collect.EntryPoints` populates `Scope.entry_points` from a host
  Phoenix router; this module owns how those elements serialise to the JSON model
  (`to_json/1`) and render to Markdown (`render/1`). Both are deterministic:
  elements are sorted by `{kind, method, path}` and the Markdown groups them by
  kind (in a fixed order) with per-group counts, so unchanged routes reproduce
  byte-identical output.

  Provenance (`source: "collected"`) is stamped on each element by the collector,
  not here — so a hand-supplied entry (e.g. a bare `%{label: ...}`) passes through
  unchanged.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Entry points"

  @kind_order ~w(browser api webhook oauth mcp other)
  @kind_titles %{
    "browser" => "Browser",
    "api" => "API",
    "webhook" => "Webhook",
    "oauth" => "OAuth",
    "mcp" => "MCP",
    "other" => "Other"
  }

  @impl true
  def heading, do: @heading

  @impl true
  def to_json(entries) do
    entries
    |> Enum.map(&Section.jsonable/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @impl true
  def render([]), do: []

  def render(entries) do
    groups = Enum.group_by(entries, &kind_of/1)

    body =
      @kind_order
      |> Enum.flat_map(fn kind ->
        case Map.get(groups, kind) do
          nil -> []
          group -> group_lines(kind, Enum.sort_by(group, &sort_key/1))
        end
      end)
      |> drop_trailing_blank()

    [@heading, "", summary_line(entries), "" | body]
  end

  defp group_lines(kind, group) do
    ["### #{title(kind)} (#{length(group)})", "" | Enum.map(group, &bullet/1)] ++ [""]
  end

  defp bullet(entry) do
    method = entry["method"]
    path = entry["path"]

    if is_binary(method) and is_binary(path) do
      "- `#{method} #{path}` → #{handler_label(entry)}#{basis_suffix(entry)}"
    else
      Section.bullet(entry)
    end
  end

  defp handler_label(entry) do
    handler = entry["handler"] || "—"

    case entry["action"] do
      action when is_binary(action) -> "#{handler}##{action}"
      _ -> handler
    end
  end

  defp basis_suffix(entry) do
    case entry["basis"] do
      basis when is_binary(basis) -> " — _#{basis}_"
      _ -> ""
    end
  end

  defp summary_line(entries) do
    kinds = entries |> Enum.map(&kind_of/1) |> Enum.uniq() |> length()

    "_#{length(entries)} #{plural(length(entries), "entry point")} across #{kinds} #{plural(kinds, "kind")}._"
  end

  defp plural(1, word), do: word
  defp plural(_n, "entry point"), do: "entry points"
  defp plural(_n, word), do: word <> "s"

  defp title(kind), do: Map.get(@kind_titles, kind, kind)

  defp kind_of(entry), do: entry["kind"] || "other"

  defp sort_key(entry),
    do: {kind_index(kind_of(entry)), entry["method"] || "", entry["path"] || ""}

  defp kind_index(kind), do: Enum.find_index(@kind_order, &(&1 == kind)) || length(@kind_order)

  defp drop_trailing_blank(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end
end
