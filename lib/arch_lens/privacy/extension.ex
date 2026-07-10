defmodule ArchLens.Privacy do
  @moduledoc """
  Spark DSL extension that lets an `Ash.Resource` declare its privacy posture.

      defmodule MyApp.Contact do
        use Ash.Resource,
          domain: MyApp.Domain,
          extensions: [ArchLens.Privacy]

        privacy do
          data_category :contact
          retention "P30D"
          legal_basis :consent
        end
      end

  A resource that truly carries no personal data declares the `no_personal_data`
  marker *instead of* a `privacy` block:

      defmodule MyApp.FeatureFlag do
        use Ash.Resource,
          domain: MyApp.Domain,
          extensions: [ArchLens.Privacy]

        no_personal_data do
        end
      end

  Read declarations back with `ArchLens.Privacy.Info`.

  The `data_category`/`retention`/`legal_basis` vocabulary is intentionally free
  (any atom / string) at this stage; `docs/roadmap.md` records the planned
  fideslang alignment as a follow-up.
  """

  @privacy %Spark.Dsl.Section{
    name: :privacy,
    describe: """
    Declares the privacy posture of a resource that carries personal data.

    All three fields are required; a resource with no personal data uses the
    `no_personal_data` marker instead of this block.
    """,
    schema: [
      data_category: [
        type: :atom,
        required: true,
        doc: "Category of personal data the resource carries (e.g. `:contact`)."
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
    personal data. Declaring both a `privacy` block and this marker is an error.
    """,
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@privacy, @no_personal_data],
    transformers: [ArchLens.Privacy.Transformers.PersistPrivacy]
end
