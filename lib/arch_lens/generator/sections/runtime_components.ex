defmodule ArchLens.Generator.Sections.RuntimeComponents do
  @moduledoc """
  Renders the *runtime components* seam (`Scope.runtime_components`): supervised
  processes plus config-derived datastores and job runners, as collected by
  `ArchLens.Collect.Runtime`.

  Owns Markdown (`render/1`) and JSON (`to_json/1`) for the collected elements.
  Every element serialises with `source: "collected"`. Empty in, empty out — no
  section renders while the field is empty.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Runtime components"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &line/1)]

  @impl true
  def to_json(entries) do
    Enum.map(entries, fn entry ->
      entry
      |> Section.jsonable()
      |> put_source()
    end)
  end

  defp line(entry) when is_map(entry) do
    case get(entry, "label") do
      nil -> Section.bullet(entry)
      label -> "- `#{label}`#{class_suffix(entry)}#{evidence_suffix(entry)}"
    end
  end

  defp line(entry), do: Section.bullet(entry)

  defp class_suffix(entry) do
    case get(entry, "class") do
      nil -> ""
      class -> " — #{class}#{technology_suffix(entry)}"
    end
  end

  defp technology_suffix(entry) do
    case get(entry, "technology") do
      nil -> ""
      technology -> " (#{technology})"
    end
  end

  defp evidence_suffix(entry) do
    case get(entry, "evidence") do
      [_ | _] = evidence -> " [#{Enum.join(evidence, ", ")}]"
      _ -> ""
    end
  end

  defp get(entry, key), do: entry[key] || entry[String.to_atom(key)]

  defp put_source(entry) when is_map(entry), do: Map.put_new(entry, "source", "collected")
  defp put_source(entry), do: entry
end
