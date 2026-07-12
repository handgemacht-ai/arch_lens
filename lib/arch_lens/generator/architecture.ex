defmodule ArchLens.Generator.Architecture do
  @moduledoc """
  Deterministic architecture-report generator.

  `render_artifacts/1` reads the privacy posture of every Ash resource in scope
  (the union of the consuming app's domain resources and a plain module scan), the
  recorded architectural edges, and the Oban workers, folds them into one
  intermediate model (`ArchLens.Generator.Model.to_map/1`), and renders both a
  byte-stable Markdown document and a JSON sidecar from that single model. Running
  it twice against unchanged code reproduces identical bytes: every collection is
  sorted by a stable key and the output carries no timestamp, git SHA, or absolute
  filesystem path.

  ## Completeness gates

  Generation *fails* — rather than silently rendering an incomplete document —
  when any of three gates trips, each naming its offenders:

    * **privacy** — an Ash resource in scope declares neither a `privacy` block nor
      `no_personal_data` (`{:error, {:undeclared_resources, [...]}}`).
    * **style** — a top-level directory under the app namespace has no root module
      `<App>.<Dir>` (`{:error, {:missing_root_modules, [...]}}`); see
      `ArchLens.Generator.Contexts.style_gate/1`.
    * **annotation** — a discovered Ash domain or root context module carries no
      resolvable description and is not excluded
      (`{:error, {:undescribed_contexts, [...]}}`); see
      `ArchLens.Generator.Contexts.annotation_gate/1`.
    * **externals** — a collected external system is neither declared nor ignored
      (`{:error, {:undeclared_externals, [...]}}`); see
      `ArchLens.System.ExternalEvidence`.
    * **decisions** — an ADR under the decisions directory has malformed
      front-matter (`{:error, {:invalid_decisions, [...]}}`); see
      `ArchLens.Collect.Decisions`.
    * **flows** — a declared data flow references a missing element or an unbacked
      adjacency (`{:error, {:invalid_flows, [...]}}`); see
      `ArchLens.Generator.Flows`.

  ## Staleness gate

  `check/2` compares freshly rendered content against a committed artifact and
  reports drift (always naming the artifact), mirroring the
  `mix ash.codegen --check` / `mix ccc.fixtures.check` "generated artifact must
  match commit" idiom. The Markdown report and its JSON sidecar are both put under
  this gate, so `--check` fails when *either* committed file drifts.

  The generator is DB-free: it reads only compiled module metadata (source/AST),
  never a database connection.
  """

  alias ArchLens.Generator.{Contexts, Document, Flows, Model, Scope}
  alias ArchLens.Privacy.Info
  alias ArchLens.System.ExternalEvidence

  @default_artifact "docs/architecture.gen.md"
  @default_json_artifact "docs/architecture.gen.json"

  @type render_error ::
          {:undeclared_resources, [module()]}
          | {:missing_root_modules, [String.t()]}
          | {:undescribed_contexts, [String.t()]}
          | {:undeclared_externals, [String.t()]}
          | {:invalid_decisions, [{String.t(), String.t()}]}
          | {:invalid_flows, [term()]}

  @type artifacts :: %{markdown: String.t(), json: String.t()}

  @doc "The default committed Markdown artifact path (repo-relative)."
  @spec artifact() :: String.t()
  def artifact, do: @default_artifact

  @doc "The default committed JSON sidecar path (repo-relative)."
  @spec json_artifact() :: String.t()
  def json_artifact, do: @default_json_artifact

  @doc "The JSON sidecar path for a given Markdown artifact path (same stem, `.json`)."
  @spec json_artifact_for(String.t()) :: String.t()
  def json_artifact_for(markdown_path), do: Path.rootname(markdown_path) <> ".json"

  @doc """
  Renders both artifacts for `opts` (see `ArchLens.Generator.Scope`) from one
  intermediate model (`ArchLens.Generator.Model.to_map/1`), so the Markdown and its
  JSON sidecar can never disagree.

  Returns `{:ok, %{markdown: ..., json: ...}}` or
  `{:error, {:undeclared_resources, modules}}` when the completeness gate trips.
  """
  @spec render_artifacts(keyword()) :: {:ok, artifacts()} | {:error, render_error()}
  def render_artifacts(opts \\ []) do
    scope = Scope.resolve(opts)

    with :ok <- privacy_gate(scope),
         :ok <- Contexts.style_gate(scope),
         :ok <- Contexts.annotation_gate(scope),
         :ok <- externals_gate(scope),
         :ok <- decisions_gate(scope),
         :ok <- Flows.gate(scope) do
      model = Model.to_map(scope)
      {:ok, %{markdown: Document.render(model), json: Model.encode(model)}}
    end
  end

  @doc """
  Renders the architecture Markdown for `opts` (see `ArchLens.Generator.Scope`).

  Returns `{:ok, markdown}` or `{:error, {:undeclared_resources, modules}}` when
  the completeness gate trips.
  """
  @spec render(keyword()) :: {:ok, String.t()} | {:error, render_error()}
  def render(opts \\ []) do
    with {:ok, %{markdown: markdown}} <- render_artifacts(opts), do: {:ok, markdown}
  end

  @doc """
  Like `render/1` but raises `ArgumentError` on the completeness gate, so callers
  that treat an undeclared resource as fatal don't have to unwrap.
  """
  @spec render!(keyword()) :: String.t()
  def render!(opts \\ []) do
    case render(opts) do
      {:ok, markdown} -> markdown
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @doc """
  Compares freshly rendered `markdown` against the committed artifact at `path`.

  Returns `:ok` when they are byte-identical, otherwise `{:drift, path, reason}`
  — the artifact path is always named so `--check` can report exactly which file
  is stale.
  """
  @spec check(String.t(), String.t()) :: :ok | {:drift, String.t(), String.t()}
  def check(path, markdown) do
    cond do
      not File.exists?(path) -> {:drift, path, "missing committed artifact"}
      File.read!(path) == markdown -> :ok
      true -> {:drift, path, "generated output differs from committed artifact"}
    end
  end

  @doc "A human-readable message for a `render/1` error."
  @spec format_error(render_error()) :: String.t()
  def format_error({:undeclared_resources, modules}) do
    names = modules |> Enum.map(&inspect/1) |> Enum.join(", ")

    "privacy declaration missing for: #{names}. " <>
      "Every Ash.Resource in scope must declare a `privacy` block or `no_personal_data`."
  end

  def format_error({:missing_root_modules, names}) do
    "missing root module(s) for namespace directories: #{Enum.join(names, ", ")}. " <>
      "Every top-level directory under the app namespace (lib/<app>/<dir>/) must have a root " <>
      "module <App>.<Dir>; add the module, or list the directory in `ignore_namespaces` of " <>
      "your ArchLens.System block."
  end

  def format_error({:undescribed_contexts, names}) do
    "context description missing for: #{Enum.join(names, ", ")}. " <>
      "Every Ash domain and root context module must carry an ArchLens.Domain / " <>
      "ArchLens.Context annotation with a `does` or a `@moduledoc`, or set `exclude: true`."
  end

  def format_error({:undeclared_externals, vendors}) do
    "collected external system(s) without a declaration: #{Enum.join(vendors, ", ")}. " <>
      "Declare each with an `external(...)` in your ArchLens.System `architecture` block, " <>
      "or list it in `ignore_externals`."
  end

  def format_error({:invalid_decisions, offenders}) do
    lines = Enum.map_join(offenders, "; ", fn {path, reason} -> "#{path} — #{reason}" end)

    "invalid architecture decision record(s): #{lines}. " <>
      "Every `docs/decisions/NNNN-slug.md` needs a well-formed front-matter block " <>
      "(`title`, `status`, `date`)."
  end

  def format_error({:invalid_flows, offenders}) do
    "invalid data flow(s): #{Enum.join(offenders, ", ")}. " <>
      "Every flow step must resolve to a real entry point, context, or external, and " <>
      "each adjacency must be backed by evidence or marked `unverified: true`."
  end

  defp privacy_gate(%Scope{resources: resources}) do
    case Enum.sort_by(Enum.reject(resources, &Info.declared?/1), &Atom.to_string/1) do
      [] -> :ok
      undeclared -> {:error, {:undeclared_resources, undeclared}}
    end
  end

  # The externals completeness gate — delegated to the feature-owned
  # `ArchLens.System.ExternalEvidence` (a skeleton `:ok` stub until the externals
  # slice fleshes the detected-without-declaration check).
  defp externals_gate(%Scope{} = scope) do
    ExternalEvidence.gate(%{
      collected: scope.external_systems,
      declared: declared_externals(scope),
      ignore_externals: scope.ignore_externals,
      deps: scope.deps
    })
  end

  defp declared_externals(%Scope{declared_architecture: %{externals: externals}})
       when is_list(externals),
       do: externals

  defp declared_externals(_scope), do: []

  # The decisions validity gate: every indexed ADR is a well-formed, honestly
  # indexable record (parse errors collected by `ArchLens.Collect.Decisions`).
  defp decisions_gate(%Scope{decision_errors: []}), do: :ok
  defp decisions_gate(%Scope{decision_errors: errors}), do: {:error, {:invalid_decisions, errors}}
end
