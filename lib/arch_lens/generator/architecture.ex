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

  ## Completeness gate

  Generation *fails* — rather than silently rendering an incomplete document —
  when any Ash resource in scope declares neither a `privacy` block nor
  `no_personal_data`. `render/1` returns `{:error, {:undeclared_resources, [...]}}`
  in that case.

  ## Staleness gate

  `check/2` compares freshly rendered content against a committed artifact and
  reports drift (always naming the artifact), mirroring the
  `mix ash.codegen --check` / `mix ccc.fixtures.check` "generated artifact must
  match commit" idiom. The Markdown report and its JSON sidecar are both put under
  this gate, so `--check` fails when *either* committed file drifts.

  The generator is DB-free: it reads only compiled module metadata (source/AST),
  never a database connection.
  """

  alias ArchLens.Generator.{Document, Model, Scope}
  alias ArchLens.Privacy.Info

  @default_artifact "docs/architecture.gen.md"
  @default_json_artifact "docs/architecture.gen.json"

  @type render_error :: {:undeclared_resources, [module()]}
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

    case undeclared(scope.resources) do
      [] ->
        model = Model.to_map(scope)
        {:ok, %{markdown: Document.render(model), json: Model.encode(model)}}

      undeclared ->
        {:error, {:undeclared_resources, undeclared}}
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

  defp undeclared(resources) do
    resources
    |> Enum.reject(&Info.declared?/1)
    |> Enum.sort_by(&Atom.to_string/1)
  end
end
