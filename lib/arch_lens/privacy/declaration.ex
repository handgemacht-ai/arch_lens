defmodule ArchLens.Privacy.Declaration do
  @moduledoc """
  Normalized privacy declaration read back off a compiled resource.

  A resource either carries a `privacy` block (which produces this struct) or a
  `no_personal_data` marker (which does not). See `ArchLens.Privacy` for the DSL
  and `ArchLens.Privacy.Info` for the reader.
  """

  @enforce_keys [:data_category, :retention, :legal_basis]
  defstruct [:data_category, :retention, :legal_basis]

  @type t :: %__MODULE__{
          data_category: atom(),
          retention: String.t(),
          legal_basis: atom()
        }
end
