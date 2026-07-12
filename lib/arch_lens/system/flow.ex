defmodule ArchLens.System.Flow do
  @moduledoc """
  A declared data-flow story: a named, ordered sequence of hops narrating one
  end-to-end path through the app (an entry point into one or more contexts and
  out to an external system).

  Built by the `flow` entity of the `ArchLens.System` DSL and read back with
  `ArchLens.System.Info.flows/1`. Each hop is an `ArchLens.System.Flow.Step`
  carried in declaration order — order is the data. The generator resolves the
  steps and proves each adjacency against the collected architecture at generation
  time (`ArchLens.Generator.Flows`); this struct only carries the raw declaration.
  """

  @enforce_keys [:name, :does]
  defstruct [:name, :does, {:steps, []}, {:__spark_metadata__, nil}]

  @type t :: %__MODULE__{
          name: atom(),
          does: String.t(),
          steps: [ArchLens.System.Flow.Step.t()]
        }
end

defmodule ArchLens.System.Flow.Step do
  @moduledoc """
  One hop of a declared `ArchLens.System.Flow`: a reference to an entry point, a
  context, or an external system, kept in declaration order.

  `kind` discriminates which surface `ref` names — `:entry_point` (a `"METHOD /path"`
  string), `:context` (a context name atom), or `:external` (an external name atom)
  — and is stamped per step by the DSL. `does` is an optional verbatim one-line
  description of the hop. `unverified: true` is the escape hatch: it opts the hop
  out of the generator's adjacency-backing check, recording the transition as
  asserted rather than failing generation.
  """

  @enforce_keys [:kind, :ref]
  defstruct [:kind, :ref, :does, {:unverified, false}, {:__spark_metadata__, nil}]

  @type kind :: :entry_point | :context | :external

  @type t :: %__MODULE__{
          kind: kind(),
          ref: String.t() | atom(),
          does: String.t() | nil,
          unverified: boolean()
        }
end
