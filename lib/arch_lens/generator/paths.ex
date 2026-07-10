defmodule ArchLens.Generator.Paths do
  @moduledoc """
  Repo-relativises a filesystem path so no absolute path ever reaches a rendered
  artifact.

  Both the Markdown and JSON renderers go through here, so a call-site path is
  relativised exactly once, in one place. Falls back to the basename when the path
  is not under the project root.
  """

  @doc "Repo-relative form of `path`, or its basename when it is outside the project root."
  @spec relativize(Path.t()) :: Path.t()
  def relativize(path) do
    relative = Path.relative_to(path, File.cwd!())

    case Path.type(relative) do
      :absolute -> Path.basename(relative)
      _ -> relative
    end
  end
end
