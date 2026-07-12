defmodule ArchLens.Generator.Sections.Decisions do
  @moduledoc """
  Renders the *decisions* section: the architecture-decision records indexed by
  `ArchLens.Collect.Decisions`.

  `render/1` yields the `## Decisions` index — one bullet per ADR, sorted by
  number:

      - **ADR-0001** REST API consolidates on AshJsonApi — _accepted_ (2026-06-15) `docs/decisions/0001-rest-api-ashjsonapi.md`

  The path is a repo-relative **code span**, not a Markdown link: it is
  deliberately consistent with how call-site paths render elsewhere in the
  artifact, and it avoids a broken-link footgun (the artifact's own location
  varies with `--output`, and `Document.render/1` has no output-path context). The
  JSON `path` field lets rich viewers link. `render([])` yields `[]`, so an app
  with zero ADRs renders no section.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Decisions"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []

  def render(entries) do
    bullets = entries |> Enum.sort_by(&number/1) |> Enum.map(&bullet/1)
    [@heading, "" | bullets]
  end

  @impl true
  def to_json(entries) do
    entries
    |> Enum.map(&Section.jsonable/1)
    |> Enum.sort_by(&number/1)
  end

  defp bullet(entry) do
    "- **ADR-#{number(entry)}** #{entry["title"]} — _#{entry["status"]}_ (#{entry["date"]}) `#{entry["path"]}`"
  end

  defp number(entry), do: entry["number"] || ""
end
