defmodule ArchLens.Context.Info do
  @moduledoc """
  Runtime introspection for the `ArchLens.Context` in-place annotation.

  Reads the injected `__arch_lens_context__/0` declaration back off a compiled
  plain root context module, resolving the fallbacks the annotation leaves open: a
  `nil` `does` falls back to the module's `@moduledoc` first paragraph, a `nil`
  `name` to a name derived from the module. This is the plain-module counterpart of
  `ArchLens.Domain`.
  """

  alias ArchLens.Collect.ModuleDoc
  alias ArchLens.Context
  alias ArchLens.Context.Declaration

  @doc "The declared `ArchLens.Context.Declaration`, or `nil` when the module is not annotated."
  @spec declaration(module()) :: Declaration.t() | nil
  def declaration(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__arch_lens_context__, 0) do
      module.__arch_lens_context__()
    end
  end

  @doc "Whether the module carries an `ArchLens.Context` annotation."
  @spec annotated?(module()) :: boolean()
  def annotated?(module), do: match?(%Declaration{}, declaration(module))

  @doc "Whether the module is annotated `exclude: true`."
  @spec excluded?(module()) :: boolean()
  def excluded?(module) do
    match?(%Declaration{exclude: true}, declaration(module))
  end

  @doc """
  The context name: the annotated `name:`, else one derived from the module
  (`ArchLens.Context.derive_name/1`).
  """
  @spec name(module()) :: atom()
  def name(module) do
    case declaration(module) do
      %Declaration{name: name} when is_atom(name) and not is_nil(name) -> name
      _ -> Context.derive_name(module)
    end
  end

  @doc """
  The resolved description and where it came from: `{does, :annotation}` from an
  annotated `does:`, `{does, :moduledoc}` from the `@moduledoc` fallback, or
  `{nil, nil}` when neither is available.
  """
  @spec does(module()) :: {String.t(), :annotation | :moduledoc} | {nil, nil}
  def does(module) do
    case declaration(module) do
      %Declaration{does: does} when is_binary(does) -> {does, :annotation}
      _ -> moduledoc_does(module)
    end
  end

  @doc "Whether the module has a resolvable description (an annotated `does:` or a `@moduledoc`)."
  @spec described?(module()) :: boolean()
  def described?(module), do: elem(does(module), 0) != nil

  @doc """
  The handler-module namespace prefixes this context serves, from an annotated
  `interface:` (empty when none or not annotated). Used to attribute entry points.
  """
  @spec interface(module()) :: [String.t()]
  def interface(module) do
    case declaration(module) do
      %Declaration{interface: interface} when is_list(interface) -> interface
      _ -> []
    end
  end

  defp moduledoc_does(module) do
    case ModuleDoc.first_paragraph(module) do
      nil -> {nil, nil}
      doc -> {doc, :moduledoc}
    end
  end
end
