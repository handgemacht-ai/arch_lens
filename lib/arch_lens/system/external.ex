defmodule ArchLens.System.External do
  @moduledoc """
  A declared external system: a third party this app talks to, and how.

  Built by the `external` entity of the `ArchLens.System` DSL and read back with
  `ArchLens.System.Info.externals/1`. Declared externals are validated against and
  merged with the collected external systems at generation time. `evidence` carries
  an optional corroboration hint (`dep:`/`module:`/`host:`/`manual:`) the externals
  verification gate resolves.
  """

  @enforce_keys [:name, :via, :target, :does]
  defstruct [:name, :via, :target, :does, {:evidence, []}, {:__spark_metadata__, nil}]

  @type via :: :http | :subprocess | :otlp | :smtp

  @type t :: %__MODULE__{
          name: atom(),
          via: via(),
          target: String.t(),
          does: String.t(),
          evidence: keyword()
        }
end
