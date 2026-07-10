defmodule Mix.Tasks.ArchLens.Gen.Architecture.System do
  @shortdoc "Generate (or --check) the architecture report with a declared ArchLens.System"

  @moduledoc """
  Like `mix arch_lens.gen.architecture`, but also folds in the *declared*
  architecture from an `ArchLens.System` module named with `--system`.

  The declared actors, external systems, and contexts are validated against what
  the generator collected (`ArchLens.System.Declared`) before anything is written;
  an actor that claims a missing entry point, an HTTP external that matches no
  collected boundary or dependency, or a context whose module prefix names nothing
  fails generation with one message listing every problem.

  ## Usage

      mix arch_lens.gen.architecture.system --system MyApp.Architecture
      mix arch_lens.gen.architecture.system --system MyApp.Architecture --check
      mix arch_lens.gen.architecture.system --system MyApp.Architecture --output docs/arch.md

  `--system` is required — the task fails fast when it is missing.
  """

  use Mix.Task

  alias ArchLens.Generator.Architecture
  alias ArchLens.System.ValidationError

  @requirements ["compile"]

  @switches [check: :boolean, output: :string, system: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    system = system_module(opts)

    app = Mix.Project.config()[:app]
    load_app(app)

    path = Keyword.get(opts, :output, Architecture.artifact())

    try do
      Mix.Tasks.ArchLens.Gen.Architecture.emit(
        [app: app, system: system],
        path,
        Keyword.get(opts, :check, false)
      )
    rescue
      error in ValidationError -> Mix.raise(Exception.message(error))
    end
  end

  defp system_module(opts) do
    case Keyword.get(opts, :system) do
      nil -> Mix.raise("--system MyApp.Architecture is required")
      name -> Module.concat([name])
    end
  end

  defp load_app(nil), do: :ok

  defp load_app(app) do
    _ = Application.load(app)
    :ok
  end
end
