defmodule ArchLens.Generator.Sections.DeclaredArchitecture do
  @moduledoc """
  The *declared architecture* section: the architecture a team asserts on one
  app-level `ArchLens.System` module, validated against what the generator actually
  collected — the declared-vs-collected gate, one rung above
  `ArchLens.Generator.Retention`.

  `Scope.declared_architecture` is either the structured value the model assembles
  (`%{actors, contexts, warnings}`) or a plain list of generic entries. For the
  structured value this module renders an **Actors** section and a **Contexts**
  section (declared *externals* are merged into the External systems section by
  `ArchLens.Generator.Model`), plus any skipped-validation warnings. Every entry
  carries `source: "declared"`, distinct from the `collected` things it is checked
  against.

  Contexts are the resolved in-place contexts from `ArchLens.Generator.Contexts`:
  each renders its name, description, and `origin` (Ash domain, context module, or
  the deprecated central declaration), and a domain-backed context also lists its
  resource membership.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Declared architecture"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []

  def render(entries) when is_list(entries) do
    [@heading, "" | Enum.map(entries, &Section.bullet/1)]
  end

  def render(%{} = declared) do
    [
      actors_block(Map.get(declared, "actors", [])),
      contexts_block(Map.get(declared, "contexts", [])),
      warnings_block(Map.get(declared, "warnings", []))
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([""])
    |> List.flatten()
  end

  @impl true
  def to_json(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      entry
      |> Section.jsonable()
      |> put_source()
    end)
  end

  def to_json(%{} = declared) do
    %{
      "actors" => declared |> Map.get(:actors, []) |> Enum.map(&Section.jsonable/1),
      "contexts" => declared |> Map.get(:contexts, []) |> Enum.map(&Section.jsonable/1),
      "warnings" => declared |> Map.get(:warnings, []) |> Enum.map(&to_string/1)
    }
  end

  defp actors_block([]), do: []
  defp actors_block(actors), do: ["## Actors", "" | Enum.map(actors, &actor_bullet/1)]

  defp contexts_block([]), do: []

  defp contexts_block(contexts),
    do: ["## Contexts", "" | Enum.flat_map(contexts, &context_lines/1)]

  defp warnings_block([]), do: []
  defp warnings_block(warnings), do: Enum.map(warnings, &"> validation skipped: #{&1}")

  defp actor_bullet(actor) do
    "- **#{actor["name"]}** — #{actor["does"]}#{uses_suffix(actor["uses"])}"
  end

  defp uses_suffix(uses) when uses in [nil, []], do: ""
  defp uses_suffix(uses), do: " (uses: #{Enum.join(uses, ", ")})"

  defp context_lines(context) do
    [
      "- **#{context["name"]}** — #{context["does"]}#{origin_suffix(context)}"
      | resource_lines(context)
    ]
  end

  defp origin_suffix(context) do
    case context["origin"] do
      "domain" -> " _(Ash domain)_"
      "context_module" -> " _(context module)_"
      "central_declared" -> " _(central declaration, deprecated)_"
      _ -> ""
    end
  end

  defp resource_lines(%{"resources" => [_ | _] = resources}) do
    ["  - resources: " <> Enum.map_join(resources, ", ", &"`#{&1}`")]
  end

  defp resource_lines(_context), do: []

  defp put_source(entry) when is_map(entry), do: Map.put_new(entry, "source", "declared")
  defp put_source(entry), do: entry
end
