defmodule ArchLens.System.Info do
  @moduledoc """
  Runtime introspection for the `ArchLens.System` DSL.

  Reads the declared actors, external systems, and contexts back off a compiled
  module that `use ArchLens.System`.
  """

  alias ArchLens.System.{Actor, Context, External}
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

  @doc "All declared architecture entities grouped by kind."
  @spec architecture(system()) :: %{
          actors: [Actor.t()],
          externals: [External.t()],
          contexts: [Context.t()]
        }
  def architecture(system) do
    %{actors: actors(system), externals: externals(system), contexts: contexts(system)}
  end

  # `get_persisted` raises for a module that never went through the DSL. Reading a
  # non-`ArchLens.System` module back as "declared nothing" is friendlier than a
  # crash, so a plain module is treated as empty.
  defp persisted(system, key) when is_atom(system) do
    if spark_dsl?(system), do: Extension.get_persisted(system, key, []), else: []
  end

  defp persisted(system, key), do: Extension.get_persisted(system, key, [])

  defp spark_dsl?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0)
  end
end
