defmodule ArchLens.Context.Declaration do
  @moduledoc """
  Normalized in-place context annotation read back off a plain root context module.

  A module declares one with `use ArchLens.Context, does: "...", name: :foo,
  exclude: false, interface: ["MyAppWeb.Foo"]`; `ArchLens.Context.Info` reads this
  struct back, resolving the `does`/`name` fallbacks the annotation deliberately
  leaves open (a `nil` `does` falls back to the module's `@moduledoc`, a `nil`
  `name` to a derived one). `interface` names the handler-module namespaces the
  context serves, used to attribute entry points.

  This is the plain-module counterpart to the `ArchLens.Domain` extension, which
  carries the same fields on an `Ash.Domain`.
  """

  defstruct [:does, :name, exclude: false, interface: []]

  @type t :: %__MODULE__{
          does: String.t() | nil,
          name: atom() | nil,
          exclude: boolean(),
          interface: [String.t()]
        }
end
