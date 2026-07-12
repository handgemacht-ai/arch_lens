defmodule ArchLens.Context do
  @moduledoc """
  In-place annotation for a plain (non-Ash) *root context module*.

  The convention it anchors: `lib/my_app/judge.ex` is the root facade of the
  `lib/my_app/judge/` directory, so `MyApp.Judge` is the context that owns that
  namespace. Annotate it in place:

      defmodule MyApp.Judge do
        @moduledoc "Scores marketing copy against the brand judges."
        use ArchLens.Context, does: "scores copy against the brand judges"
      end

  All four options are optional:

    * `does:` — a one-line description; when omitted it falls back to the module's
      `@moduledoc` first paragraph (`ArchLens.Collect.ModuleDoc`).
    * `name:` — the context's name; when omitted it is derived from the module's
      last segment (`derive_name/1`).
    * `exclude:` — `true` marks a genuine non-context root that should be left out
      of the architecture model and skipped by the annotation gate.
    * `interface:` — a list of handler-module namespace prefixes this context
      serves (e.g. `["MyAppWeb.JudgeController"]`), used to attribute entry points
      to it; empty leaves them unattributed rather than guessing.

  `use ArchLens.Context` injects a `__arch_lens_context__/0` function the generator
  reads back through `ArchLens.Context.Info`. This mirrors how `ArchLens.Domain`
  carries the same fields on an `Ash.Domain`; a plain module cannot host a Spark
  DSL, so the annotation is a compiled function rather than a persisted attribute.
  """

  @generic_leaves ~w(Data Domain Store)

  @doc """
  Injects `__arch_lens_context__/0`, returning the `ArchLens.Context.Declaration`
  for the module. `does`/`name`/`exclude`/`interface` must be compile-time literals
  of the right type, or compilation fails fast.
  """
  defmacro __using__(opts) do
    does = Keyword.get(opts, :does)
    name = Keyword.get(opts, :name)
    exclude = Keyword.get(opts, :exclude, false)
    interface = Keyword.get(opts, :interface, [])

    validate!(:does, does, &(is_nil(&1) or is_binary(&1)))
    validate!(:name, name, &(is_nil(&1) or is_atom(&1)))
    validate!(:exclude, exclude, &is_boolean/1)
    validate!(:interface, interface, &(is_list(&1) and Enum.all?(&1, fn v -> is_binary(v) end)))

    quote do
      @doc false
      def __arch_lens_context__ do
        %ArchLens.Context.Declaration{
          does: unquote(does),
          name: unquote(name),
          exclude: unquote(exclude),
          interface: unquote(interface)
        }
      end
    end
  end

  @doc """
  The context name derived from a module's last segment, snake-cased.

  A generic leaf segment (`Data`, `Domain`, `Store`) is dropped in favour of the
  segment before it, mirroring `AshAdmin.Domain`'s default naming — so
  `MyApp.Billing.Store` derives `:billing` and `MyApp.Accounts` derives
  `:accounts`.
  """
  @spec derive_name(module()) :: atom()
  def derive_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> significant_segment()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp significant_segment(segments) do
    case List.last(segments) do
      leaf when leaf in @generic_leaves and length(segments) > 1 -> Enum.at(segments, -2)
      leaf -> leaf
    end
  end

  defp validate!(key, value, ok?) when is_function(ok?, 1) do
    if ok?.(value) do
      :ok
    else
      raise ArgumentError,
            "ArchLens.Context expects a literal value for `#{key}`; got #{inspect(value)}."
    end
  end
end
