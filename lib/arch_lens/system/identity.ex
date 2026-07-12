defmodule ArchLens.System.Identity do
  @moduledoc """
  The app's declared town identity: the stable id it is known by across apps, an
  optional display name, and the address aliases other apps' externals resolve to
  it by (scheme or host tokens such as `"havi"` or `"havi.handgemacht.ai"`).

  Built by the `identity` entity of the `ArchLens.System` DSL and read back with
  `ArchLens.System.Info.identity/1`. Declared at most once per app and consumed by
  the town-level combiner (`ArchLens.Town`) to resolve cross-app links; this struct
  only carries the raw declaration.
  """

  @enforce_keys [:id]
  defstruct [:id, :name, {:aliases, []}, {:__spark_metadata__, nil}]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t() | nil,
          aliases: [String.t()]
        }
end
