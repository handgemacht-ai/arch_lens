defmodule ArchLens.Privacy do
  @categories [
    :contact,
    :identifier,
    :credential,
    :content,
    :usage,
    :consent,
    :organization,
    :financial,
    :profile,
    :membership
  ]

  @moduledoc """
  Spark DSL extension that lets an `Ash.Resource` declare its privacy posture.

      defmodule MyApp.Contact do
        use Ash.Resource,
          domain: MyApp.Domain,
          extensions: [ArchLens.Privacy]

        privacy do
          categories [:contact, :content]
          retention "P30D"
          legal_basis :consent
        end
      end

  `categories` is a non-empty list drawn from a closed, library-governed
  vocabulary — `#{inspect(@categories)}`. A value outside the set fails
  compilation with a `Spark.Error.DslError` naming the bad atom; widening the
  vocabulary is a deliberate edit to the single `@categories` list in this
  module, never a per-app decision.

  A resource that truly carries no personal data declares the `no_personal_data`
  marker *instead of* a `privacy` block:

      no_personal_data do
      end

  A resource that is PII-capable but deliberately left unclassified declares the
  reason-bearing `privacy_exempt` marker *instead* — the reason is required and
  non-blank so the exemption stays auditable:

      privacy_exempt do
        reason "legacy import table, scheduled for deletion in Q3"
      end

  Exactly one of `privacy`, `no_personal_data`, or `privacy_exempt` may be
  declared. Read declarations back with `ArchLens.Privacy.Info`.

  The singular `data_category` option is retained as a deprecated legacy alias
  for `categories`; prefer `categories`. `retention` and `legal_basis` are still
  free vocabulary at this stage; `docs/roadmap.md` records the planned fideslang
  alignment as a follow-up.
  """

  @privacy %Spark.Dsl.Section{
    name: :privacy,
    describe: """
    Declares the privacy posture of a resource that carries personal data.

    Provide a non-empty `categories` list drawn from the closed vocabulary, plus
    the required `retention` and `legal_basis`. A resource with no personal data
    uses the `no_personal_data` marker instead; a PII-capable resource left
    deliberately unclassified uses the `privacy_exempt` marker instead.
    """,
    schema: [
      categories: [
        type: {:list, {:one_of, @categories}},
        required: false,
        doc: "Non-empty list of personal-data categories from the closed vocabulary."
      ],
      data_category: [
        type: :atom,
        required: false,
        doc: "Deprecated singular alias for `categories`; prefer `categories`."
      ],
      retention: [
        type: :string,
        required: true,
        doc: "Retention policy, e.g. an ISO-8601 duration like \"P30D\"."
      ],
      legal_basis: [
        type: :atom,
        required: true,
        doc: "GDPR Art. 6 legal basis, e.g. `:consent` or `:contract`."
      ]
    ]
  }

  @no_personal_data %Spark.Dsl.Section{
    name: :no_personal_data,
    describe: """
    Marker declared *instead of* a `privacy` block by resources that carry no
    personal data. Declaring it alongside a `privacy` block or `privacy_exempt`
    is an error.
    """,
    schema: []
  }

  @privacy_exempt %Spark.Dsl.Section{
    name: :privacy_exempt,
    describe: """
    Marker declared *instead of* a `privacy` block by a PII-capable resource that
    is deliberately left unclassified. The `reason` is required and must be
    non-blank so the exemption is auditable. Declaring it alongside a `privacy`
    block or `no_personal_data` is an error.
    """,
    schema: [
      reason: [
        type: :string,
        required: true,
        doc: "Why the resource is exempt from classification (required, non-blank)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@privacy, @no_personal_data, @privacy_exempt],
    transformers: [ArchLens.Privacy.Transformers.PersistPrivacy]

  @doc """
  The closed privacy-category vocabulary, governed in this one place.

  A `categories` value must be a non-empty subset of this list.
  """
  @spec categories() :: [atom()]
  def categories, do: @categories
end
