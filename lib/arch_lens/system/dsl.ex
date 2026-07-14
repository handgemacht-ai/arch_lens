defmodule ArchLens.System.Dsl do
  @moduledoc """
  The Spark DSL extension backing `ArchLens.System`.

  Defines the `architecture` section and its entities — `actor`, `external`,
  `context`, `flow`, and `identity` — plus the transformer that persists them for
  `ArchLens.System.Info`. This mirrors the `ArchLens.Privacy` extension: a section
  with a schema, a persist transformer, and an `Info` reader.

  A `flow` nests ordered `entry_point` / `context` / `external` step entities that
  narrate one end-to-end path; `identity` names the app's town identity and
  aliases; the section-level `ignore_externals` option and the per-`external`
  `evidence:` hint feed the externals verification gates. The generator resolves
  and gates all of these at generation time — the DSL only carries the declaration.
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
            "`:oauth`, `:mcp`, `:cron`, `:channel`, `:task`, `:other`; e.g. " <>
            "`[:api, :mcp, :browser]`. Validated against the collected entry points at " <>
            "generation time."
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
      ],
      evidence: [
        type: :keyword_list,
        default: [],
        doc:
          "Optional evidence hint corroborating a declared external the collector did " <>
            "not detect on its own — any of `dep: :some_dep`, `module: \"Prefix\"`, " <>
            "`host: \"api.example.com\"`, or the escape hatch `manual: \"reason\"`. " <>
            "Resolved and gated at generation time (`ArchLens.System.ExternalEvidence`)."
      ]
    ]
  }

  @flow_entry_point %Spark.Dsl.Entity{
    name: :entry_point,
    describe: """
    A flow hop naming a collected entry point by its `"METHOD /path"`.
    """,
    examples: [
      ~s|entry_point "POST /api/annotations", does: "extension posts the envelope"|
    ],
    target: ArchLens.System.Flow.Step,
    args: [:ref],
    auto_set_fields: [kind: :entry_point],
    schema: [
      ref: [
        type: :string,
        required: true,
        doc: ~s|The entry point, as `"METHOD /path"` (e.g. `"POST /api/annotations"`).|
      ],
      does: [
        type: :string,
        required: false,
        doc: "Optional one-line description of this hop."
      ],
      unverified: [
        type: :boolean,
        default: false,
        doc: "When `true`, assert this hop's adjacency instead of proving it (escape hatch)."
      ]
    ]
  }

  @flow_context %Spark.Dsl.Entity{
    name: :context,
    describe: """
    A flow hop naming a bounded context of the app.
    """,
    examples: [
      ~s|context :annotations, does: "validates and persists the envelope"|
    ],
    target: ArchLens.System.Flow.Step,
    args: [:ref],
    auto_set_fields: [kind: :context],
    schema: [
      ref: [
        type: :atom,
        required: true,
        doc: "The context name, e.g. `:annotations`."
      ],
      does: [
        type: :string,
        required: false,
        doc: "Optional one-line description of this hop."
      ],
      unverified: [
        type: :boolean,
        default: false,
        doc: "When `true`, assert this hop's adjacency instead of proving it (escape hatch)."
      ]
    ]
  }

  @flow_external %Spark.Dsl.Entity{
    name: :external,
    describe: """
    A flow hop naming an external system the app talks to.
    """,
    examples: [
      ~s|external :stripe, does: "charges the customer"|
    ],
    target: ArchLens.System.Flow.Step,
    args: [:ref],
    auto_set_fields: [kind: :external],
    schema: [
      ref: [
        type: :atom,
        required: true,
        doc: "The external system name, e.g. `:stripe`."
      ],
      does: [
        type: :string,
        required: false,
        doc: "Optional one-line description of this hop."
      ],
      unverified: [
        type: :boolean,
        default: false,
        doc: "When `true`, assert this hop's adjacency instead of proving it (escape hatch)."
      ]
    ]
  }

  @flow %Spark.Dsl.Entity{
    name: :flow,
    describe: """
    A named, ordered data-flow story: an entry point into one or more contexts and
    out to an external system, each step optionally described in place.

    Steps are kept in declaration order — order is the data. The generator resolves
    each step and proves each adjacency against the collected architecture; a step
    can opt out of that check with `unverified: true`.
    """,
    examples: [
      ~s|flow :annotation_capture, does: "capture path" do\n  entry_point "POST /api/annotations"\n  context :annotations\nend|
    ],
    target: ArchLens.System.Flow,
    args: [:name],
    entities: [steps: [@flow_entry_point, @flow_context, @flow_external]],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The flow's name, e.g. `:annotation_capture`."
      ],
      does: [
        type: :string,
        required: true,
        doc: "One-line, verbatim description of the whole flow."
      ]
    ]
  }

  @identity %Spark.Dsl.Entity{
    name: :identity,
    describe: """
    The app's town identity: the stable id it is known by across apps, an optional
    display name, and the address aliases other apps' externals resolve to it by.

    Declared at most once per app; consumed by the town-level combiner.
    """,
    examples: [
      ~s|identity :havi, name: "HAVI", aliases: ["havi", "havi.handgemacht.ai"]|
    ],
    target: ArchLens.System.Identity,
    args: [:id],
    schema: [
      id: [
        type: :atom,
        required: true,
        doc: "The app's stable town id, e.g. `:havi`."
      ],
      name: [
        type: :string,
        required: false,
        doc: "Optional display name; falls back to the id when omitted."
      ],
      aliases: [
        type: {:list, :string},
        default: [],
        doc:
          "Scheme or host tokens other apps' externals resolve to this app by, " <>
            "e.g. `[\"havi\", \"havi.handgemacht.ai\"]`."
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
          "Top-level directory names (e.g. `:fixtures`, `:e2e`) under the app namespace that " <>
            "the style and annotation gates should skip — genuine support directories that are " <>
            "not bounded contexts. Names match leniently, so `:e2e` matches an `E2E` directory."
      ],
      ignore_externals: [
        type: {:list, :atom},
        default: [],
        doc:
          "Detected external vendors or deps (e.g. `:opentelemetry`) the externals " <>
            "completeness gate should not require a declaration for. Ignored externals still " <>
            "render, tagged `verification: \"ignored\"` — never silently omitted. Names match " <>
            "leniently by slug."
      ]
    ],
    entities: [@actor, @external, @context, @flow, @identity]
  }

  use Spark.Dsl.Extension,
    sections: [@architecture],
    transformers: [ArchLens.System.Transformers.PersistArchitecture]
end
