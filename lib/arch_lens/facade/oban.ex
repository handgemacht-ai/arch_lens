defmodule ArchLens.Facade.Oban do
  @moduledoc """
  Thin facade over `Oban.insert/1,2`, behind an optional-dependency guard.

  Oban is an optional dependency of `arch_lens` (see `mix.exs`), so nothing here
  may hard-require it: the module references Oban only through `apply/3` and a bare
  module atom, never a direct `Oban.some_fun(...)` call, so it compiles and its
  tests pass whether or not Oban is in the dependency tree.

  `oban_insert/1,2` emits a runtime pass-through to `insert/1,2`, which forwards
  the changeset unchanged to `Oban.insert/1,2` when Oban is loadable and returns
  `{:error, :oban_not_loaded}` when it is not. As with the other facades, one
  `:oban_insert` `ArchLens.Edge` is recorded at compile time, keyed by
  `{builder, call_site}` (the builder being the worker behind the changeset).

  The enclosing module must `use ArchLens.Facade` so the edge can be collected.

      defmodule Demo.Enqueue do
        use ArchLens.Facade

        def welcome(user_id) do
          oban_insert(Demo.WelcomeWorker.new(%{user_id: user_id}))
        end
      end

  Tests (and callers that want a fake) can inject the insert target with
  `config :arch_lens, :oban_module, MyStub`; setting it to `false` or `nil`
  forces the not-loaded path.
  """

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry
  alias ArchLens.Facade
  alias ArchLens.Facade.Builder

  @doc "Facade over `Oban.insert/1`."
  defmacro oban_insert(changeset) do
    put_oban_edge(__CALLER__, changeset)

    quote do
      unquote(__MODULE__).insert(unquote(changeset))
    end
  end

  @doc "Facade over `Oban.insert/2`."
  defmacro oban_insert(changeset, opts) do
    put_oban_edge(__CALLER__, changeset)

    quote do
      unquote(__MODULE__).insert(unquote(changeset), unquote(opts))
    end
  end

  @doc """
  Runtime pass-through to `Oban.insert/1,2`.

  Forwards `changeset` (and `opts`, when given) unchanged. Returns
  `{:error, :oban_not_loaded}` when no Oban insert target is available.
  """
  @spec insert(term()) :: term()
  def insert(changeset) do
    case oban_module() do
      nil -> {:error, :oban_not_loaded}
      module -> apply(module, :insert, [changeset])
    end
  end

  @spec insert(term(), keyword()) :: term()
  def insert(changeset, opts) do
    case oban_module() do
      nil -> {:error, :oban_not_loaded}
      module -> apply(module, :insert, [changeset, opts])
    end
  end

  @doc "Whether an Oban insert target is available (real Oban or an injected one)."
  @spec available?() :: boolean()
  def available?, do: not is_nil(oban_module())

  defp oban_module do
    case Application.fetch_env(:arch_lens, :oban_module) do
      {:ok, module} when module in [nil, false] -> nil
      {:ok, module} -> module
      :error -> if Registry.oban_available?(), do: Oban, else: nil
    end
  end

  defp put_oban_edge(caller, changeset_ast) do
    Facade.put_edge(caller.module, %Edge{
      kind: :oban_insert,
      builder: Builder.from_call(changeset_ast, caller),
      call_sites: [{caller.file, caller.line}],
      target: Macro.to_string(changeset_ast)
    })
  end
end
