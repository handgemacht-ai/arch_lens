defmodule ArchLens.Generator.Sections.DataFlows do
  @moduledoc """
  Renders the *data flows* section: the named, ordered flow stories resolved by
  `ArchLens.Generator.Flows`.

  Each flow renders as `### <name>`, its verbatim `_does_` line, then an ordered
  list of hops. Every hop shows its kind, a friendly label for its canonical `ref`,
  its verbatim `does` (when present), and a terse backing suffix pointing at the
  structured proof id — a dependency edge, an http boundary edge, an entry binding,
  or the visible `_asserted_` escape hatch. The proof stays a stable id, never
  tool-authored prose. Flows arrive already sorted by name and their steps in
  declaration order; that order is preserved, so unchanged declarations reproduce
  byte-identical Markdown. Empty in, empty out.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Data flows"

  @kind_labels %{
    "entry_point" => "entry point",
    "context" => "context",
    "external" => "external"
  }

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []

  def render(flows) do
    body =
      flows
      |> Enum.map(&flow_block/1)
      |> Enum.intersperse([""])
      |> List.flatten()

    [@heading, "" | body]
  end

  @impl true
  def to_json(flows), do: Enum.map(flows, &Section.jsonable/1)

  defp flow_block(flow) do
    [
      "### #{flow[:name]}",
      "",
      "_#{flow[:does]}_",
      ""
      | steps(flow[:steps])
    ]
  end

  defp steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, n} -> "#{n}. #{step_line(step)}" end)
  end

  defp step_line(step) do
    "**#{kind_label(step[:kind])}** `#{label(step)}`" <>
      does_suffix(step[:does]) <> backing_suffix(step[:backed_by])
  end

  defp kind_label(kind), do: Map.get(@kind_labels, kind, kind)

  # A friendly display of the canonical ref: a route id as its `METHOD /path`, a
  # context or external id with its prefix dropped.
  defp label(%{kind: "entry_point", ref: "route:" <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [method, path] -> "#{method} #{path}"
      _ -> rest
    end
  end

  defp label(%{kind: "context", ref: "context:" <> name}), do: name
  defp label(%{kind: "external", ref: "external:" <> slug}), do: slug
  defp label(%{ref: ref}), do: ref

  defp does_suffix(does) when is_binary(does) and does != "", do: " — #{does}"
  defp does_suffix(_does), do: ""

  defp backing_suffix(nil), do: ""
  defp backing_suffix(%{type: "asserted"}), do: " ← _asserted_"

  defp backing_suffix(%{type: type, ref: ref}),
    do: " ← #{backing_label(type)} `#{ref}`"

  defp backing_label("dependency_edge"), do: "dependency edge"
  defp backing_label("http_boundary"), do: "http boundary"
  defp backing_label("entry_binding"), do: "entry binding"
  defp backing_label(other), do: other
end
