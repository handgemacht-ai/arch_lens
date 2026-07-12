defmodule ArchLens.Privacy.Declaration do
  @moduledoc """
  Normalized privacy declaration read back off a compiled resource.

  A resource either carries a `privacy` block (which produces this struct) or a
  `no_personal_data` / `privacy_exempt` marker (which do not). See
  `ArchLens.Privacy` for the DSL and `ArchLens.Privacy.Info` for the reader.

  `categories` is the closed-vocabulary list; `data_category` is the deprecated
  singular alias retained for legacy declarations. Exactly one of the two is
  expected on a `privacy` block; `retention` and `legal_basis` are always
  present.
  """

  @enforce_keys [:retention, :legal_basis]
  defstruct [:categories, :data_category, :retention, :legal_basis]

  @type t :: %__MODULE__{
          categories: [atom()] | nil,
          data_category: atom() | nil,
          retention: String.t(),
          legal_basis: atom()
        }
end
