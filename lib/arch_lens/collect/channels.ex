defmodule ArchLens.Collect.Channels do
  @moduledoc """
  Collects Phoenix channel entry points: each user socket's declared channels.

  This is the wave-2 skeleton stub: `collect/1` returns `[]`, so no `:channel`
  entry points surface and the empty-v3 baseline renders. The wave-3 entry-points
  slice fleshes it to reflect each endpoint's `socket` mounts and every user
  socket's `__channels__/0`, emitting one element per topic pattern.
  """

  @doc """
  Channel entry-point elements collected from the app's sockets.

  Skeleton stub — always `[]`. Fleshed by the entry-points slice.
  """
  @spec collect(keyword()) :: [map()]
  def collect(_opts \\ []), do: []
end
