defmodule ArchLens.System.Info do
  @moduledoc """
  Runtime introspection for the `ArchLens.System` DSL.

  Reads the declared actors, external systems, contexts, flows, and town identity
  back off a compiled module that `use ArchLens.System`.
  """

  alias ArchLens.System.{Actor, Context, External, Flow, Identity}
  alias Spark.Dsl.Extension

  @type system :: Spark.Dsl.t() | module()

  @doc "The declared actors, sorted deterministically (empty when none)."
  @spec actors(system()) :: [Actor.t()]
  def actors(system), do: persisted(system, :arch_lens_actors)

  @doc "The declared external systems, sorted deterministically (empty when none)."
  @spec externals(system()) :: [External.t()]
  def externals(system), do: persisted(system, :arch_lens_externals)

  @doc "The declared contexts, sorted deterministically (empty when none)."
  @spec contexts(system()) :: [Context.t()]
  def contexts(system), do: persisted(system, :arch_lens_contexts)

  @doc "The declared flows, sorted by name (empty when none); steps keep declaration order."
  @spec flows(system()) :: [Flow.t()]
  def flows(system), do: persisted(system, :arch_lens_flows)

  @doc "The declared town identity, or `nil` when none was declared."
  @spec identity(system()) :: Identity.t() | nil
  def identity(system) when is_atom(system) do
    if spark_dsl?(system), do: read_identity(system), else: nil
  end

  def identity(system), do: read_identity(system)

  @doc """
  The top-level namespace directory names the style and annotation gates should
  skip, as declared by `ignore_namespaces` on the `architecture` section (empty
  when none, or for a non-`ArchLens.System` module).
  """
  @spec ignore_namespaces(system()) :: [atom()]
  def ignore_namespaces(system) when is_atom(system) do
    if spark_dsl?(system), do: read_ignore_namespaces(system), else: []
  end

  def ignore_namespaces(system), do: read_ignore_namespaces(system)

  @doc """
  The detected external vendors/deps the externals completeness gate should not
  require a declaration for, as declared by `ignore_externals` on the
  `architecture` section (empty when none, or for a non-`ArchLens.System` module).
  """
  @spec ignore_externals(system()) :: [atom()]
  def ignore_externals(system) when is_atom(system) do
    if spark_dsl?(system), do: read_ignore_externals(system), else: []
  end

  def ignore_externals(system), do: read_ignore_externals(system)

  @doc "All declared architecture entities grouped by kind (flows included)."
  @spec architecture(system()) :: %{
          actors: [Actor.t()],
          externals: [External.t()],
          contexts: [Context.t()],
          flows: [Flow.t()]
        }
  def architecture(system) do
    %{
      actors: actors(system),
      externals: externals(system),
      contexts: contexts(system),
      flows: flows(system)
    }
  end

  # `get_persisted` raises for a module that never went through the DSL. Reading a
  # non-`ArchLens.System` module back as "declared nothing" is friendlier than a
  # crash, so a plain module is treated as empty.
  defp persisted(system, key) when is_atom(system) do
    if spark_dsl?(system), do: Extension.get_persisted(system, key, []), else: []
  end

  defp persisted(system, key), do: Extension.get_persisted(system, key, [])

  defp read_ignore_namespaces(system) do
    Extension.get_opt(system, [:architecture], :ignore_namespaces, [])
  end

  defp read_ignore_externals(system) do
    Extension.get_opt(system, [:architecture], :ignore_externals, [])
  end

  defp read_identity(system) do
    Extension.get_persisted(system, :arch_lens_identity, nil)
  end

  defp spark_dsl?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0)
  end
end
