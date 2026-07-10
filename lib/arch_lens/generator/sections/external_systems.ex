defmodule ArchLens.Generator.Sections.ExternalSystems do
  @moduledoc """
  Seam for the *external systems* slice (third parties this app talks to: Stripe,
  Cloudflare, S3, …, beyond the raw `:http_boundary` edges).

  A stub the external-systems slice fills in: it owns Markdown (`render/1`) and
  JSON (`to_json/1`) for `Scope.external_systems`, plus the host-app wrapper that
  populates the field. Empty while unpopulated, so no section renders yet.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## External systems"

  @impl true
  def heading, do: @heading

  @impl true
  def render([]), do: []
  def render(entries), do: [@heading, "" | Enum.map(entries, &Section.bullet/1)]

  @impl true
  def to_json(entries), do: Enum.map(entries, &Section.jsonable/1)
end
