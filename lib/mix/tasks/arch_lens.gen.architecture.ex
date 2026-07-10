defmodule Mix.Tasks.ArchLens.Gen.Architecture do
  @shortdoc "Generate (or --check) the deterministic architecture privacy report"

  @moduledoc """
  Renders the deterministic architecture/privacy report for the current app and
  writes it to `docs/architecture.gen.md` (or `--output PATH`).

  ## Usage

      mix arch_lens.gen.architecture            # write the report
      mix arch_lens.gen.architecture --check    # fail on drift, write nothing
      mix arch_lens.gen.architecture --output docs/arch.md

  ## `--check` mode

  Re-renders the report and compares it byte-for-byte against the committed
  artifact, exiting non-zero and *naming the artifact* on any drift. This mirrors
  the `mix ash.codegen --check` / `mix ccc.fixtures.check` idiom and is the
  completeness/staleness gate a consuming app wires into CI.

  Generation *fails* (non-zero) — rather than emitting an incomplete document —
  when any `Ash.Resource` in scope declares neither a `privacy` block nor
  `no_personal_data`.

  The task is DB-free: it loads the app to read compiled module metadata but
  never starts it, so no repository/database connection is opened.
  """

  use Mix.Task

  alias ArchLens.Generator.Architecture

  @requirements ["compile"]

  @switches [check: :boolean, output: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    app = Mix.Project.config()[:app]
    load_app(app)

    path = Keyword.get(opts, :output, Architecture.artifact())

    emit([app: app], path, Keyword.get(opts, :check, false))
  end

  @doc false
  # Render `render_opts`, then either write to `path` or (in `--check` mode)
  # compare against it. Rendering an undeclared resource, or drift in `--check`,
  # aborts via `Mix.raise/1` (non-zero exit). Split out so the write/check/raise
  # glue is exercised with an explicit scope in tests.
  @spec emit(keyword(), String.t(), boolean()) :: :ok
  def emit(render_opts, path, check?) do
    markdown =
      case Architecture.render(render_opts) do
        {:ok, markdown} -> markdown
        {:error, reason} -> Mix.raise(Architecture.format_error(reason))
      end

    if check? do
      check(path, markdown)
    else
      write(path, markdown)
    end
  end

  # Load (do not start) the app so `:application.get_key/2` sees its module list
  # and any edge-registering modules are available, without opening a database.
  defp load_app(nil), do: :ok

  defp load_app(app) do
    _ = Application.load(app)
    :ok
  end

  defp check(path, markdown) do
    case Architecture.check(path, markdown) do
      :ok ->
        Mix.shell().info("architecture report up to date: #{path}")

      {:drift, ^path, reason} ->
        Mix.raise(
          "architecture report is stale: #{path} (#{reason}). " <>
            "Run `mix arch_lens.gen.architecture` and commit #{path}."
        )
    end
  end

  defp write(path, markdown) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, markdown)
    Mix.shell().info("wrote architecture report: #{path}")
  end
end
