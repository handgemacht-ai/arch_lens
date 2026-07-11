defmodule ArchLens.Domain do
  @moduledoc """
  Spark DSL extension that lets an `Ash.Domain` describe itself as a bounded
  context, in place, next to its resources:

      defmodule MyApp.Accounts do
        use Ash.Domain, extensions: [ArchLens.Domain]

        architecture do
          does "users, workspaces, and memberships"
        end

        resources do
          resource MyApp.Accounts.User
          resource MyApp.Accounts.Workspace
        end
      end

  All three options are optional:

    * `does` — a one-line description; when omitted it falls back to the domain's
      `@moduledoc` first paragraph (`ArchLens.Collect.ModuleDoc`).
    * `name` — the context name; when omitted it is derived from the domain's last
      segment (`ArchLens.Context.derive_name/1`, dropping generic leaves like
      `Domain`/`Data`/`Store`).
    * `exclude` — `true` leaves the domain out of the architecture model and skips
      it in the annotation gate.

  The context's resource membership is taken from `Ash.Domain.Info.resources/1`.
  This is the `Ash.Domain` counterpart of `ArchLens.Context` (which annotates a
  plain root module), modelled on the `AshAdmin.Domain` precedent; the reader
  helpers (`does/1`, `name/1`, `excluded?/1`) resolve the same fallbacks
  `ArchLens.Context.Info` does.
  """

  alias ArchLens.Collect.ModuleDoc
  alias ArchLens.Context
  alias Spark.Dsl.Extension

  @architecture %Spark.Dsl.Section{
    name: :architecture,
    describe: """
    Describes this domain as a bounded context of the app: what it does, its name,
    and whether to exclude it from the architecture model.
    """,
    examples: [
      ~s|architecture do\n  does "users and workspaces"\nend|
    ],
    schema: [
      does: [
        type: :string,
        required: false,
        doc: "One-line description of the context. Falls back to the `@moduledoc` when omitted."
      ],
      name: [
        type: :atom,
        required: false,
        doc: "The context's name. Derived from the module's last segment when omitted."
      ],
      exclude: [
        type: :boolean,
        default: false,
        doc: "When `true`, omit this domain from the architecture model and the annotation gate."
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@architecture]

  @doc "Whether the domain carries the `ArchLens.Domain` extension."
  @spec annotated?(module()) :: boolean()
  def annotated?(domain), do: __MODULE__ in Spark.extensions(domain)

  @doc "Whether the domain declared `architecture do exclude true end`."
  @spec excluded?(module()) :: boolean()
  def excluded?(domain) do
    annotated?(domain) and get_opt(domain, :exclude, false) == true
  end

  @doc """
  The context name: the declared `name`, else one derived from the module
  (`ArchLens.Context.derive_name/1`).
  """
  @spec name(module()) :: atom()
  def name(domain) do
    (annotated?(domain) && get_opt(domain, :name, nil)) || Context.derive_name(domain)
  end

  @doc """
  The resolved description and where it came from: `{does, :annotation}` from a
  declared `does`, `{does, :moduledoc}` from the `@moduledoc` fallback, or
  `{nil, nil}` when neither is available.
  """
  @spec does(module()) :: {String.t(), :annotation | :moduledoc} | {nil, nil}
  def does(domain) do
    case annotated?(domain) && get_opt(domain, :does, nil) do
      does when is_binary(does) -> {does, :annotation}
      _ -> moduledoc_does(domain)
    end
  end

  @doc "Whether the domain has a resolvable description (a declared `does` or a `@moduledoc`)."
  @spec described?(module()) :: boolean()
  def described?(domain), do: elem(does(domain), 0) != nil

  defp get_opt(domain, key, default) do
    Extension.get_opt(domain, [:architecture], key, default, true)
  end

  defp moduledoc_does(domain) do
    case ModuleDoc.first_paragraph(domain) do
      nil -> {nil, nil}
      doc -> {doc, :moduledoc}
    end
  end
end
