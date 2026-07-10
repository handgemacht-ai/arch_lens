defmodule ArchLens.Edge do
  @moduledoc """
  One architectural edge recorded by a facade macro.

  An edge is a *semantic* boundary crossing that a facade wraps:

    * `:topic` — a PubSub topic-builder call-site,
    * `:oban_insert` — an Oban-insert call-site,
    * `:http_boundary` — an HTTP / boundary declaration.

  ## Stable identity

  An edge's identity is `{kind, canonical builder, canonical target}` — it never
  contains a file or line. Every call-site that resolves to the same identity is
  the *same* edge; the individual sites are carried as an attribute list,
  `call_sites`, so N call-sites collapse into one semantic edge:

    * `builder` — the module (or MFA / `{module, name}` tuple) that constructs the
      edge, e.g. the topic builder or the Oban worker,
    * `target` — the concrete thing the edge points at (a topic string, an Oban
      worker module, a boundary URL),
    * `call_sites` — the sorted list of `{file, line}` sites the facade wrapped,
    * `metadata` — anything else a builder wants the generator to see.

  `canonical_builder/1` and `canonical_target/1` render the builder and target to
  the stable, path-free strings the identity and the rendered artifacts use.
  """

  @kinds [:topic, :oban_insert, :http_boundary]

  @enforce_keys [:kind, :builder]
  defstruct [:kind, :builder, :target, call_sites: [], metadata: %{}]

  @type kind :: :topic | :oban_insert | :http_boundary
  @type call_site :: {file :: Path.t(), line :: pos_integer()}
  @type identity :: {kind(), builder :: String.t(), target :: String.t()}

  @type t :: %__MODULE__{
          kind: kind(),
          builder: module() | mfa() | {module(), atom()} | String.t(),
          target: term(),
          call_sites: [call_site()],
          metadata: map()
        }

  @doc "The edge kinds a facade may register."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The semantic identity of an edge: `{kind, canonical builder, canonical target}`.

  Free of file and line, so two call-sites that cross the same boundary share an
  identity and merge into one edge.
  """
  @spec identity(t()) :: identity()
  def identity(%__MODULE__{kind: kind, builder: builder, target: target}) do
    {kind, canonical_builder(builder), canonical_target(target)}
  end

  @doc "A stable, path-free string id for the edge element."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{} = edge) do
    {kind, builder, target} = identity(edge)
    "edge:#{kind}:#{builder}=>#{target}"
  end

  @doc "A deterministic sort key ordering edges by kind, then builder, then target."
  @spec sort_key(t()) :: {String.t(), String.t(), String.t()}
  def sort_key(%__MODULE__{} = edge) do
    {kind, builder, target} = identity(edge)
    {Atom.to_string(kind), builder, target}
  end

  @doc "Render the builder half of an edge to its canonical, path-free string."
  @spec canonical_builder(term()) :: String.t()
  def canonical_builder({module, fun, arity})
      when is_atom(module) and is_atom(fun) and is_integer(arity) do
    "#{module_name(module)}.#{fun}/#{arity}"
  end

  def canonical_builder({module, name}) when is_atom(module) and is_atom(name) do
    "#{module_name(module)}:#{name}"
  end

  def canonical_builder(module) when is_atom(module) and not is_nil(module) do
    module_name(module)
  end

  def canonical_builder(builder) when is_binary(builder), do: builder
  def canonical_builder(other), do: inspect(other)

  @doc "Render the target half of an edge to its canonical, path-free string."
  @spec canonical_target(term()) :: String.t()
  def canonical_target(target) when is_binary(target), do: target
  def canonical_target(nil), do: ""

  def canonical_target(target) when is_atom(target) and target not in [true, false],
    do: module_name(target)

  def canonical_target(other), do: inspect(other)

  @doc false
  def module_name(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end
end

defmodule ArchLens.Edge.Registry do
  @moduledoc """
  Registry the facade macros write to and the generator reads from.

  A facade macro registers exactly one `ArchLens.Edge` per wrapped call-site;
  registration is keyed by the edge's *semantic identity*
  (`ArchLens.Edge.identity/1` — `{kind, canonical builder, canonical target}`),
  never by file/line. Two call-sites that cross the same boundary therefore
  **merge** into a single edge whose `call_sites` is the union of both sites
  (sorted, de-duplicated).

  `all/0` returns the merged edges in a stable order so the generator's output is
  deterministic. The store is a lazily-started named `Agent`; `start_link/1` and
  `child_spec/1` are provided for callers that prefer to supervise it explicitly.
  """

  alias ArchLens.Edge

  @doc false
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registers a single edge, merging it into any edge with the same identity.

  Registering a second edge whose `{kind, builder, target}` matches an existing
  one unions their `call_sites` and metadata rather than replacing it. Returns the
  merged edge.
  """
  @spec register(Edge.t()) :: {:ok, Edge.t()}
  def register(%Edge{kind: kind} = edge) do
    unless kind in Edge.kinds() do
      raise ArgumentError,
            "unknown edge kind #{inspect(kind)}, expected one of #{inspect(Edge.kinds())}"
    end

    ensure_started()

    merged =
      Agent.get_and_update(__MODULE__, fn state ->
        key = Edge.identity(edge)

        merged =
          case Map.get(state, key) do
            nil -> normalize(edge)
            existing -> merge(existing, edge)
          end

        {merged, Map.put(state, key, merged)}
      end)

    {:ok, merged}
  end

  @doc "Every registered edge, merged and in a stable, deterministic order."
  @spec all() :: [Edge.t()]
  def all do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      state |> Map.values() |> Enum.sort_by(&Edge.sort_key/1)
    end)
  end

  @doc "Fetch the merged edge for an edge (by its identity) or an identity tuple."
  @spec fetch(Edge.t() | Edge.identity()) :: {:ok, Edge.t()} | :error
  def fetch(%Edge{} = edge), do: do_fetch(Edge.identity(edge))
  def fetch(identity) when is_tuple(identity), do: do_fetch(identity)

  @doc "How many distinct edges are registered."
  @spec count() :: non_neg_integer()
  def count do
    ensure_started()
    Agent.get(__MODULE__, &map_size/1)
  end

  @doc "Drop every registered edge (useful for tests and re-generation)."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  @doc "The semantic identity key for an edge."
  @spec key(Edge.t()) :: Edge.identity()
  def key(%Edge{} = edge), do: Edge.identity(edge)

  @doc """
  Whether Oban is loadable. Facade edge-builders gate any Oban-touching code
  behind this so `arch_lens` compiles and runs with Oban absent.
  """
  @spec oban_available?() :: boolean()
  def oban_available?, do: Code.ensure_loaded?(Oban)

  @doc false
  def ensure_started do
    case start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp do_fetch(identity) do
    ensure_started()
    Agent.get(__MODULE__, &Map.fetch(&1, identity))
  end

  defp normalize(%Edge{} = edge) do
    %{edge | call_sites: sort_call_sites(edge.call_sites)}
  end

  defp merge(%Edge{} = existing, %Edge{} = incoming) do
    %{
      existing
      | call_sites: sort_call_sites(existing.call_sites ++ incoming.call_sites),
        target: existing.target || incoming.target,
        metadata: Map.merge(existing.metadata, incoming.metadata)
    }
  end

  defp sort_call_sites(sites) do
    sites |> Enum.uniq() |> Enum.sort()
  end
end
