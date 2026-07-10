defmodule ArchLens.Privacy.Transformers.PersistPrivacy do
  @moduledoc """
  Normalizes the declared `privacy` block (or `no_personal_data` marker) into
  persisted values that `ArchLens.Privacy.Info` reads back at runtime, and
  rejects resources that declare both.

  Persists:

    * `:arch_lens_privacy` — an `ArchLens.Privacy.Declaration` struct, or `nil`.
    * `:arch_lens_no_personal_data` — a boolean.
  """

  use Spark.Dsl.Transformer

  alias ArchLens.Privacy.Declaration
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def transform(dsl_state) do
    has_privacy? = Map.has_key?(dsl_state, [:privacy])
    has_no_personal_data? = Map.has_key?(dsl_state, [:no_personal_data])

    if has_privacy? and has_no_personal_data? do
      {:error, both_declared_error(dsl_state)}
    else
      dsl_state =
        dsl_state
        |> Transformer.persist(:arch_lens_privacy, declaration(dsl_state, has_privacy?))
        |> Transformer.persist(:arch_lens_no_personal_data, has_no_personal_data?)

      {:ok, dsl_state}
    end
  end

  defp declaration(_dsl_state, false), do: nil

  defp declaration(dsl_state, true) do
    %Declaration{
      data_category: Transformer.get_option(dsl_state, [:privacy], :data_category),
      retention: Transformer.get_option(dsl_state, [:privacy], :retention),
      legal_basis: Transformer.get_option(dsl_state, [:privacy], :legal_basis)
    }
  end

  defp both_declared_error(dsl_state) do
    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:privacy],
      message:
        "declare either a `privacy` block or `no_personal_data`, not both — " <>
          "the `no_personal_data` marker is used instead of a `privacy` block."
    )
  end
end
