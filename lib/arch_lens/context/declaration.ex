defmodule ArchLens.Context.Declaration do
  @moduledoc """
  Normalized in-place context annotation read back off a plain root context module.

  A module declares one with `use ArchLens.Context, does: "...", name: :foo,
  exclude: false`; `ArchLens.Context.Info` reads this struct back, resolving the
  `does`/`name` fallbacks the annotation deliberately leaves open (a `nil` `does`
  falls back to the module's `@moduledoc`, a `nil` `name` to a derived one).

  This is the plain-module counterpart to the `ArchLens.Domain` extension, which
  carries the same three fields on an `Ash.Domain`.
  """

  defstruct [:does, :name, exclude: false]

  @type t :: %__MODULE__{
          does: String.t() | nil,
          name: atom() | nil,
          exclude: boolean()
        }
end
