defmodule ArchLens.Facade do
  @moduledoc """
  Entry point for the edge/topic facades.

  `use ArchLens.Facade` in a module that crosses an architectural boundary — a
  module that broadcasts/subscribes over `Phoenix.PubSub`, inserts Oban jobs, or
  talks to an external HTTP party. It imports the facade macros
  (`ArchLens.Facade.Topic.deftopic/2`, `ArchLens.Facade.PubSub.broadcast/3,4` and
  `subscribe/2,3`, `ArchLens.Facade.Oban.oban_insert/1,2`,
  `ArchLens.Facade.Boundary.boundary/1,2`) and wires the module to collect the
  edges those macros declare.

  Every facade macro is a *thin* wrapper: the runtime code it emits is
  byte-identical to the equivalent raw call. The only extra thing a facade does is
  record one `ArchLens.Edge` — keyed by `{builder, call_site}` — so the edge
  inventory (see `ArchLens.Edge.Registry`) can see the boundary crossing.

  Collection works in two layers:

    * at compile time, each macro accumulates its `ArchLens.Edge` into the
      `@arch_lens_edges` module attribute, exposed after compilation as
      `__arch_lens_edges__/0`;
    * after the module compiles, `__after_compile__/2` registers those edges into
      `ArchLens.Edge.Registry`, so an edge appears in the registry keyed by
      `{builder, call_site}` as soon as a facade call site compiles.

  `register_edges/1` re-runs registration on demand (useful for tests and for the
  generator, which resets the registry before re-collecting).
  """

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry

  @doc false
  defmacro __using__(_opts) do
    module = __CALLER__.module

    unless Module.has_attribute?(module, :arch_lens_edges) do
      Module.register_attribute(module, :arch_lens_edges, accumulate: true, persist: true)
      Module.put_attribute(module, :before_compile, ArchLens.Facade)
      Module.put_attribute(module, :after_compile, ArchLens.Facade)
    end

    quote do
      import ArchLens.Facade.Topic, only: [deftopic: 2]

      import ArchLens.Facade.PubSub,
        only: [broadcast: 3, broadcast: 4, subscribe: 2, subscribe: 3]

      import ArchLens.Facade.Oban, only: [oban_insert: 1, oban_insert: 2]
      import ArchLens.Facade.Boundary, only: [boundary: 1, boundary: 2]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    edges =
      env.module
      |> Module.get_attribute(:arch_lens_edges, [])
      |> Enum.reverse()
      |> Macro.escape()

    quote do
      @doc false
      def __arch_lens_edges__, do: unquote(edges)
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    register_edges(env.module)
    :ok
  end

  @doc """
  Accumulate one `edge` onto the compiling `module`.

  Called by the facade macros while the caller module is still open. Returns the
  edge unchanged.
  """
  @spec put_edge(module(), Edge.t()) :: Edge.t()
  def put_edge(module, %Edge{} = edge) do
    Module.put_attribute(module, :arch_lens_edges, edge)
    edge
  end

  @doc """
  Register every edge that `module` declared via facade macros into
  `ArchLens.Edge.Registry`.

  Returns the list of registered edges. Registration is deduplicated on the
  `{builder, call_site}` key, so calling this twice is idempotent.
  """
  @spec register_edges(module()) :: [Edge.t()]
  def register_edges(module) do
    module
    |> edges()
    |> Enum.map(fn %Edge{} = edge ->
      {:ok, registered} = Registry.register(edge)
      registered
    end)
  end

  @doc "The edges `module` declared, or `[]` when it declared none."
  @spec edges(module()) :: [Edge.t()]
  def edges(module) do
    if function_exported?(module, :__arch_lens_edges__, 0) do
      module.__arch_lens_edges__()
    else
      []
    end
  end
end
