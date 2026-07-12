defmodule ArchLens.Privacy.Transformers.PersistPrivacy do
  @moduledoc """
  Normalizes the declared `privacy` block (or `no_personal_data` / `privacy_exempt`
  marker) into persisted values that `ArchLens.Privacy.Info` reads back at
  runtime, and rejects a resource that declares more than one posture.

  Persists:

    * `:arch_lens_privacy` — an `ArchLens.Privacy.Declaration` struct, or `nil`.
    * `:arch_lens_no_personal_data` — a boolean.
    * `:arch_lens_privacy_exempt` — the exemption reason string, or `nil`.

  Gates enforced here (declaration-time):

    * exactly one of `privacy` / `no_personal_data` / `privacy_exempt`,
    * a `privacy` block declares a non-empty category (`categories` list, or the
      legacy `data_category`),
    * a `privacy_exempt` marker carries a non-blank `reason`.

  The closed `categories` vocabulary itself is enforced by the Spark
  `{:list, {:one_of, …}}` schema type in `ArchLens.Privacy`.
  """

  use Spark.Dsl.Transformer

  alias ArchLens.Privacy.Declaration
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def transform(dsl_state) do
    has_privacy? = Map.has_key?(dsl_state, [:privacy])
    has_no_personal_data? = Map.has_key?(dsl_state, [:no_personal_data])
    has_exempt? = Map.has_key?(dsl_state, [:privacy_exempt])

    postures = Enum.count([has_privacy?, has_no_personal_data?, has_exempt?], & &1)

    cond do
      postures > 1 ->
        {:error, multiple_declared_error(dsl_state)}

      has_privacy? ->
        with :ok <- validate_categories(dsl_state) do
          {:ok, persist(dsl_state, has_privacy?, has_no_personal_data?, has_exempt?)}
        end

      has_exempt? ->
        with :ok <- validate_reason(dsl_state) do
          {:ok, persist(dsl_state, has_privacy?, has_no_personal_data?, has_exempt?)}
        end

      true ->
        {:ok, persist(dsl_state, has_privacy?, has_no_personal_data?, has_exempt?)}
    end
  end

  defp persist(dsl_state, has_privacy?, has_no_personal_data?, has_exempt?) do
    dsl_state
    |> Transformer.persist(:arch_lens_privacy, declaration(dsl_state, has_privacy?))
    |> Transformer.persist(:arch_lens_no_personal_data, has_no_personal_data?)
    |> Transformer.persist(:arch_lens_privacy_exempt, exempt_reason(dsl_state, has_exempt?))
  end

  defp validate_categories(dsl_state) do
    categories = Transformer.get_option(dsl_state, [:privacy], :categories)
    data_category = Transformer.get_option(dsl_state, [:privacy], :data_category)

    cond do
      categories == [] -> {:error, empty_categories_error(dsl_state)}
      is_nil(categories) and is_nil(data_category) -> {:error, no_category_error(dsl_state)}
      true -> :ok
    end
  end

  defp validate_reason(dsl_state) do
    reason = Transformer.get_option(dsl_state, [:privacy_exempt], :reason)

    if is_binary(reason) and String.trim(reason) != "" do
      :ok
    else
      {:error, blank_reason_error(dsl_state)}
    end
  end

  defp declaration(_dsl_state, false), do: nil

  defp declaration(dsl_state, true) do
    %Declaration{
      categories: Transformer.get_option(dsl_state, [:privacy], :categories),
      data_category: Transformer.get_option(dsl_state, [:privacy], :data_category),
      retention: Transformer.get_option(dsl_state, [:privacy], :retention),
      legal_basis: Transformer.get_option(dsl_state, [:privacy], :legal_basis)
    }
  end

  defp exempt_reason(_dsl_state, false), do: nil

  defp exempt_reason(dsl_state, true) do
    Transformer.get_option(dsl_state, [:privacy_exempt], :reason)
  end

  defp multiple_declared_error(dsl_state) do
    dsl_error(
      dsl_state,
      [:privacy],
      "declare only one of `privacy`, `no_personal_data`, or `privacy_exempt`, not both — " <>
        "the `no_personal_data` and `privacy_exempt` markers are used instead of a " <>
        "`privacy` block, never alongside it."
    )
  end

  defp empty_categories_error(dsl_state) do
    dsl_error(
      dsl_state,
      [:privacy, :categories],
      "`categories` must be a non-empty list — declare `no_personal_data` for a resource " <>
        "with no personal data, or `privacy_exempt` to opt out with a reason."
    )
  end

  defp no_category_error(dsl_state) do
    dsl_error(
      dsl_state,
      [:privacy, :categories],
      "a `privacy` block must declare a non-empty `categories` list from the closed " <>
        "vocabulary (see `ArchLens.Privacy`)."
    )
  end

  defp blank_reason_error(dsl_state) do
    dsl_error(
      dsl_state,
      [:privacy_exempt, :reason],
      "`privacy_exempt` requires a non-blank `reason` explaining why the resource is " <>
        "exempt from classification."
    )
  end

  defp dsl_error(dsl_state, path, message) do
    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: path,
      message: message
    )
  end
end
