defmodule ArchLens.System.Transformers.PersistArchitecture do
  @moduledoc """
  Normalizes the declared `architecture` entities into persisted, deterministically
  sorted lists that `ArchLens.System.Info` reads back at runtime, and rejects a
  block that declares two entities of the same kind under the same name.

  Persists:

    * `:arch_lens_actors` — sorted `ArchLens.System.Actor` structs.
    * `:arch_lens_externals` — sorted `ArchLens.System.External` structs.
    * `:arch_lens_contexts` — sorted `ArchLens.System.Context` structs.
    * `:arch_lens_flows` — `ArchLens.System.Flow` structs sorted by name (each flow's
      steps keep declaration order).
    * `:arch_lens_identity` — the single declared `ArchLens.System.Identity` struct,
      or `nil`; more than one is rejected.
  """

  use Spark.Dsl.Transformer

  alias ArchLens.System.{Actor, Context, External, Flow, Identity}
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def transform(dsl_state) do
    entities = Transformer.get_entities(dsl_state, [:architecture])

    actors = entities |> only(Actor) |> Enum.sort_by(&to_string(&1.name))

    externals =
      entities
      |> only(External)
      |> Enum.sort_by(&{to_string(&1.via), &1.target, to_string(&1.name)})

    contexts = entities |> only(Context) |> Enum.sort_by(&to_string(&1.name))
    flows = entities |> only(Flow) |> Enum.sort_by(&to_string(&1.name))
    identities = only(entities, Identity)

    with :ok <- ensure_unique(dsl_state, :actor, actors),
         :ok <- ensure_unique(dsl_state, :external, externals),
         :ok <- ensure_unique(dsl_state, :context, contexts),
         :ok <- ensure_unique(dsl_state, :flow, flows),
         :ok <- ensure_single_identity(dsl_state, identities) do
      dsl_state =
        dsl_state
        |> Transformer.persist(:arch_lens_actors, actors)
        |> Transformer.persist(:arch_lens_externals, externals)
        |> Transformer.persist(:arch_lens_contexts, contexts)
        |> Transformer.persist(:arch_lens_flows, flows)
        |> Transformer.persist(:arch_lens_identity, List.first(identities))

      {:ok, dsl_state}
    end
  end

  defp only(entities, struct), do: Enum.filter(entities, &is_struct(&1, struct))

  defp ensure_single_identity(_dsl_state, identities) when length(identities) <= 1, do: :ok

  defp ensure_single_identity(dsl_state, _identities) do
    {:error,
     DslError.exception(
       module: Transformer.get_persisted(dsl_state, :module),
       path: [:architecture, :identity],
       message: "at most one identity may be declared."
     )}
  end

  defp ensure_unique(dsl_state, kind, entities) do
    duplicates =
      entities
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] -> :ok
      names -> {:error, duplicate_error(dsl_state, kind, names)}
    end
  end

  defp duplicate_error(dsl_state, kind, names) do
    listed = names |> Enum.map(&inspect/1) |> Enum.join(", ")

    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:architecture, kind],
      message: "duplicate #{kind} name(s): #{listed} — each #{kind} must be declared once."
    )
  end
end
