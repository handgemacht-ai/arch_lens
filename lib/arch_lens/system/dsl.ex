defmodule ArchLens.System.Dsl do
  @moduledoc """
  The Spark DSL extension backing `ArchLens.System`.

  Defines the `architecture` section and its three entities — `actor`, `external`
  and `context` — plus the transformer that persists them for
  `ArchLens.System.Info`. This mirrors the `ArchLens.Privacy` extension: a section
  with a schema, a persist transformer, and an `Info` reader.
  """

  @actor %Spark.Dsl.Entity{
    name: :actor,
    describe: """
    A human or system that drives the app through one or more entry points.
    """,
    examples: [
      ~s|actor :developer, uses: [:browser, :api, :mcp], does: "captures annotations"|
    ],
    target: ArchLens.System.Actor,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The actor's name, e.g. `:developer`."
      ],
      uses: [
        type: {:list, :atom},
        default: [],
        doc:
          "Entry-point kinds the actor drives — any of `:browser`, `:api`, `:webhook`, " <>
            "`:oauth`, `:mcp`, `:other`; e.g. `[:api, :mcp, :browser]`. Validated against " <>
            "the collected entry points at generation time."
      ],
      does: [
        type: :string,
        required: true,
        doc: "One-line description of what the actor does."
      ]
    ]
  }

  @external %Spark.Dsl.Entity{
    name: :external,
    describe: """
    A third party this app talks to, and the transport it talks over.
    """,
    examples: [
      ~s|external :stripe, via: :http, target: "https://api.stripe.com", does: "billing"|
    ],
    target: ArchLens.System.External,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The external system's name, e.g. `:stripe`."
      ],
      via: [
        type: {:one_of, [:http, :subprocess, :otlp, :smtp]},
        required: true,
        doc: "Transport used to reach the external system."
      ],
      target: [
        type: :string,
        required: true,
        doc: "The concrete target: a URL or a command."
      ],
      does: [
        type: :string,
        required: true,
        doc: "One-line description of what the external system is for."
      ]
    ]
  }

  @context %Spark.Dsl.Entity{
    name: :context,
    describe: """
    A named bounded context of the app.

    **Deprecated.** Prefer annotating the context in place — an `Ash.Domain` with
    the `ArchLens.Domain` extension, or a plain root module with `use
    ArchLens.Context`. Central `context` entities still work during migration but
    emit a deprecation warning at generation time; when a context is both declared
    here and annotated in place, the in-place annotation wins.
    """,
    examples: [
      ~s|context :accounts, does: "users and workspaces", modules: "MyApp.Accounts"|
    ],
    target: ArchLens.System.Context,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The context's name or module, e.g. `:accounts`."
      ],
      does: [
        type: :string,
        required: true,
        doc: "One-line description of what the context owns."
      ],
      modules: [
        type: :string,
        required: false,
        doc: "Module prefix housing the context (for non-Ash-domain contexts)."
      ]
    ]
  }

  @architecture %Spark.Dsl.Section{
    name: :architecture,
    describe: """
    Declares the app-level architecture a team asserts: the actors that drive it,
    the external systems it depends on, and the bounded contexts it is made of.

    The declarations are validated against what the generator actually collected —
    an honesty gate one rung above the resource-level privacy declarations.
    """,
    schema: [
      ignore_namespaces: [
        type: {:list, :atom},
        default: [],
        doc:
          "Top-level directory names (snake_cased, e.g. `:fixtures`, `:e2e`) under the app " <>
            "namespace that the style and annotation gates should skip — genuine support " <>
            "directories that are not bounded contexts."
      ]
    ],
    entities: [@actor, @external, @context]
  }

  use Spark.Dsl.Extension,
    sections: [@architecture],
    transformers: [ArchLens.System.Transformers.PersistArchitecture]
end
