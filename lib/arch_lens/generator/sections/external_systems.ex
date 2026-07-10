defmodule ArchLens.Generator.Sections.ExternalSystems do
  @moduledoc """
  Renders the *external systems* seam (`Scope.external_systems`): the third
  parties this app talks to (Stripe, Sentry, mail providers, OpenTelemetry, …),
  as collected and merged by `ArchLens.Collect.Externals`.

  Owns Markdown (`render/1`) and JSON (`to_json/1`) for the collected elements.
  Each system carries `source: "collected"` and the evidence (dependency, Swoosh
  adapter, HTTP boundary edge) that surfaced it. Empty in, empty out — no section
  renders while the field is empty.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## External systems"

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
    case get(entry, "vendor") do
      nil -> Section.bullet(entry)
      vendor -> "- **#{vendor}**#{category_suffix(entry)}#{evidence_suffix(entry)}"
    end
  end

  defp line(entry), do: Section.bullet(entry)

  defp category_suffix(entry) do
    case get(entry, "category") do
      nil -> ""
      category -> " — #{category}"
    end
  end

  defp evidence_suffix(entry) do
    case get(entry, "evidence") do
      [_ | _] = evidence -> " (#{evidence |> Enum.map(&evidence_label/1) |> Enum.join(", ")})"
      _ -> ""
    end
  end

  defp evidence_label(evidence) when is_map(evidence) do
    type = get(evidence, "type")
    value = get(evidence, "value")

    case {type, value} do
      {nil, nil} -> inspect(evidence)
      {type, nil} -> to_string(type)
      {nil, value} -> to_string(value)
      {type, value} -> "#{type} #{value}"
    end
  end

  defp evidence_label(evidence), do: to_string(evidence)

  defp get(entry, key), do: entry[key] || entry[String.to_atom(key)]

  defp put_source(entry) when is_map(entry), do: Map.put_new(entry, "source", "collected")
  defp put_source(entry), do: entry
end
