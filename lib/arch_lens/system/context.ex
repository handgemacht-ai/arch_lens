defmodule ArchLens.System.Context do
  @moduledoc """
  A declared bounded context: a named area of the app.

  Built by the `context` entity of the `ArchLens.System` DSL and read back with
  `ArchLens.System.Info.contexts/1`. A non-Ash-domain context names the module
  prefix that houses it via `modules:`, which is validated against the app's real
  modules at generation time.
  """

  @enforce_keys [:name, :does]
  defstruct [:name, :does, :modules, {:__spark_metadata__, nil}]

  @type t :: %__MODULE__{
          name: atom(),
          does: String.t(),
          modules: String.t() | nil
        }
end
