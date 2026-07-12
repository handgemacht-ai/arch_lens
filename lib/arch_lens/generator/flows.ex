defmodule ArchLens.Generator.Flows do
  @moduledoc """
  Resolves and validates the declared data-flow stories against the fully-built
  `ArchLens.Generator.Scope`.

  A flow is a named, ordered sequence of hops (entry point → context → external)
  carried raw on `Scope.declared_architecture.flows` by the `ArchLens.System` DSL.
  This module resolves each step's `ref` to a real element and proves each
  consecutive pair with a derived dependency edge, an HTTP-boundary edge, or an
  entry→context binding, emitting the top-level `flows` list.

  This is the wave-2 skeleton stub: `resolve/1` returns `[]` and `gate/1` returns
  `:ok`, so the empty-v3 baseline renders and generation passes. The wave-4 flows
  slice fleshes the hop-existence and adjacency-backing checks and the `backed_by`
  taxonomy.
  """

  alias ArchLens.Generator.Scope

  @doc """
  The resolved top-level `flows` list for `scope`.

  Skeleton stub — always `[]`. Fleshed by the flows slice.
  """
  @spec resolve(Scope.t()) :: [map()]
  def resolve(%Scope{}), do: []

  @doc """
  The flow-validity gate: `:ok`, or `{:error, {:invalid_flows, offenders}}`.

  Skeleton stub — always `:ok`. Fleshed by the flows slice.
  """
  @spec gate(Scope.t()) :: :ok | {:error, {:invalid_flows, [term()]}}
  def gate(%Scope{}), do: :ok
end
