defmodule ArchLens.Edge do
  @moduledoc """
  One architectural edge recorded by a facade macro.

  An edge is a single boundary-crossing call-site that a facade wraps:

    * `:topic` — a PubSub topic-builder call-site,
    * `:oban_insert` — an Oban-insert call-site,
    * `:http_boundary` — an HTTP / boundary declaration.

  Every edge is keyed by `{builder, call_site}` (see `ArchLens.Edge.Registry`):

    * `builder` — the module (or MFA) that constructs the edge, e.g. the topic
      builder or the Oban worker,
    * `call_site` — where the facade macro was invoked, typically a
      `{module, file, line}` or `{module, function, arity}` tuple.

  `target` names the concrete thing the edge points at (a topic string, an Oban
  worker module, a boundary name); `metadata` carries anything else a builder
  wants the generator to see.
  """

  @kinds [:topic, :oban_insert, :http_boundary]

  @enforce_keys [:kind, :builder, :call_site]
  defstruct [:kind, :builder, :call_site, :target, metadata: %{}]

  @type kind :: :topic | :oban_insert | :http_boundary
  @type call_site :: {module(), atom(), arity()} | {module(), Path.t(), pos_integer()} | term()

  @type t :: %__MODULE__{
          kind: kind(),
          builder: module() | mfa(),
          call_site: call_site(),
          target: term(),
          metadata: map()
        }

  @doc "The edge kinds a facade may register."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds
end

defmodule ArchLens.Edge.Registry do
  @moduledoc """
  Registry the facade macros write to and the generator reads from.

  A facade macro registers exactly one `ArchLens.Edge` per wrapped call-site,
  keyed by `{builder, call_site}`; a later reader (the deterministic generator)
  enumerates every registered edge via `all/0`. Nothing registers edges yet —
  this is the contract the `al-facades` and `al-gen` slices bind to.

  Registration is deduplicated on the `{builder, call_site}` key, so a call-site
  registering twice keeps a single edge. `all/0` returns edges in a stable order
  so the generator's output is deterministic.

  The store is a lazily-started named `Agent`; `start_link/1` and `child_spec/1`
  are provided for callers that prefer to supervise it explicitly.
  """

  alias ArchLens.Edge

  @type key :: {builder :: module() | mfa(), call_site :: Edge.call_site()}

  @doc false
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registers a single edge, keyed by `{builder, call_site}`.

  Registering a second edge with the same key replaces the first.
  """
  @spec register(Edge.t()) :: {:ok, Edge.t()}
  def register(%Edge{kind: kind} = edge) do
    unless kind in Edge.kinds() do
      raise ArgumentError,
            "unknown edge kind #{inspect(kind)}, expected one of #{inspect(Edge.kinds())}"
    end

    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, key(edge), edge))
    {:ok, edge}
  end

  @doc """
  Convenience constructor + register. `attrs` supplies `:kind` and optionally
  `:target` / `:metadata`.
  """
  @spec register(module() | mfa(), Edge.call_site(), Enumerable.t()) :: {:ok, Edge.t()}
  def register(builder, call_site, attrs) do
    edge =
      attrs
      |> Map.new()
      |> Map.merge(%{builder: builder, call_site: call_site})
      |> then(&struct!(Edge, &1))

    register(edge)
  end

  @doc "Every registered edge, in a stable, deterministic order."
  @spec all() :: [Edge.t()]
  def all do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      state |> Map.values() |> Enum.sort_by(&sort_key/1)
    end)
  end

  @doc "Fetch the edge registered for `{builder, call_site}`."
  @spec fetch(module() | mfa(), Edge.call_site()) :: {:ok, Edge.t()} | :error
  def fetch(builder, call_site) do
    ensure_started()
    Agent.get(__MODULE__, &Map.fetch(&1, {builder, call_site}))
  end

  @doc "How many edges are registered."
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

  @doc "The `{builder, call_site}` key for an edge."
  @spec key(Edge.t()) :: key()
  def key(%Edge{builder: builder, call_site: call_site}), do: {builder, call_site}

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

  defp sort_key(%Edge{} = edge) do
    {inspect(edge.builder), inspect(edge.call_site), edge.kind}
  end
end
