defmodule ArchLens.Generator.Sections.App do
  @moduledoc """
  Renders the *app* identity block: the app's stable id, optional display name,
  and address aliases, built by `ArchLens.Generator.Model.app_map/1`.

  This is the wave-2 skeleton stub: `render/1` renders nothing, so the empty-v3
  baseline's Markdown carries no app section while the JSON still stamps the `app`
  object (built by the model). The wave-6 cross-app slice fleshes `render/1` into
  a `## App` block consumed by the town-level combiner.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## App"

  @impl true
  def heading, do: @heading

  @doc "Markdown lines for the app block. Skeleton stub — always `[]`."
  @impl true
  def render(_app), do: []

  @impl true
  def to_json(app), do: Section.jsonable(app)
end
