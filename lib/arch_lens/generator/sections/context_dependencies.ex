defmodule ArchLens.Generator.Sections.ContextDependencies do
  @moduledoc """
  Renders the *context dependencies* section: the cross-context dependency edges
  aggregated by `ArchLens.Generator.ContextEdges` from collected call references.

  Each edge renders as `- `from` → `to` (N referencing modules; e.g. `FromModule` →
  `ToModule` at file:line)`, quoting the source-context reference count and one
  deterministic sample call site (the sample's `:line` is dropped when it was not
  resolved). An empty edge list renders nothing, so the section is absent from an app
  with no collected cross-context dependencies.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Context dependencies"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(edges), do: [@heading, "" | Enum.map(edges, &line/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)

  defp line(edge) do
    "- `#{edge.from}` → `#{edge.to}` (#{referencing(edge.reference_count)}; e.g. #{example(edge.sample)})"
  end

  defp referencing(1), do: "1 referencing module"
  defp referencing(count), do: "#{count} referencing modules"

  defp example(sample) do
    "`#{sample.from_module}` → `#{sample.to_module}` at #{location(sample)}"
  end

  defp location(%{file: file, line: line}), do: "#{file}:#{line}"
  defp location(%{file: file}), do: file
end
