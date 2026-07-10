defmodule ArchLens.System.Actor do
  @moduledoc """
  A declared actor: a human or system that drives the app through one or more of
  its entry points.

  Built by the `actor` entity of the `ArchLens.System` DSL and read back with
  `ArchLens.System.Info.actors/1`.
  """

  @enforce_keys [:name, :does]
  defstruct [:name, :does, {:uses, []}, {:__spark_metadata__, nil}]

  @type t :: %__MODULE__{
          name: atom(),
          does: String.t(),
          uses: [atom()]
        }
end
