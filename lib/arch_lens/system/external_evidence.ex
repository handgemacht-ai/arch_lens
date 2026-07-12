defmodule ArchLens.System.ExternalEvidence do
  @moduledoc """
  The single source of truth for the externals verification gates: whether a
  declared external is corroborated by code evidence, and whether every collected
  external is declared.

  This is the wave-2 skeleton stub: `resolve/2` reports every declared external as
  `:corroborated` with no evidence and `gate/1` returns `:ok`, so the empty-v3
  baseline compiles and the gate chain passes. The wave-3 externals slice fleshes
  it to match a declared external against collected ids/hosts or a declared
  `evidence:` hint (`corroborated` / `manual` / `:unevidenced`) and to fail the
  completeness gate for a collected external that no declaration or
  `ignore_externals` entry covers.
  """

  @doc """
  The evidence verdict for a declared `external` in `context`.

  Skeleton stub — always `{:corroborated, []}`. Fleshed by the externals slice.
  """
  @spec resolve(map(), map()) :: {:corroborated | :manual | :unevidenced, [map()]}
  def resolve(_external, _context), do: {:corroborated, []}

  @doc """
  The externals completeness gate: `:ok`, or
  `{:error, {:undeclared_externals, vendors}}` when a collected external is neither
  declared nor ignored.

  `context` carries `:collected`, `:declared`, `:ignore_externals`, and `:deps`.
  Skeleton stub — always `:ok`. Fleshed by the externals slice.
  """
  @spec gate(map()) :: :ok | {:error, {:undeclared_externals, [String.t()]}}
  def gate(_context), do: :ok
end
