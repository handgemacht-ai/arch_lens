defmodule ArchLens.Collect.Tasks do
  @moduledoc """
  Collects the app's Mix task modules into `:task` entry-point elements — the CLI
  surface, a first-class inbound seam alongside routes, cron, and channels.

  A Mix task is any `Mix.Tasks.*` module that `use`s `Mix.Task` (it carries the
  `Mix.Task` behaviour and exports `run/1`). `collect/1` is the host-app seam: given
  an `:app`, it reads that app's *production* module list through
  `ArchLens.Generator.Scan.mix_tasks/1` — the same lib-only scan the resource and
  Oban-worker discovery use — and folds each task into a stable-id element. A caller
  may instead pass an explicit `:mix_task_modules` list (the deterministic escape
  hatch used by the tests), which bypasses the scan.

  ## Lib-only scope (why some tasks are honestly out)

  Discovery runs through the lib-only scan (`ArchLens.Generator.Scan`), so only Mix
  tasks compiled from the project's `lib/` directory are reported. Mix tasks that
  live under `lib/` are prod-compiled and belong to the app's inbound surface, so
  they are in scope. A task compiled from `test/support` (or any non-`lib/`
  `elixirc_path`) is *not* production code and stays honestly out of scope — the
  same environment-independence rule that keeps every artifact byte-identical under
  `:dev` and `:test`.

  ## Extraction (verbatim, never invented)

  Each element carries:

    * `command` — `"mix <name>"`, where `<name>` is derived from the module name the
      way Mix itself does (`Mix.Task.task_name/1`, e.g.
      `Mix.Tasks.My_app.Foo` → `my_app.foo`).
    * `description` — the task's `@shortdoc`, read verbatim via
      `Mix.Task.shortdoc/1`. A task with no `@shortdoc` carries no `description` key
      at all (honest nil — nothing is invented to fill the gap).
    * `handler` — the task module, so the existing `interface`/namespace attribution
      (`ArchLens.Generator.Attribution`) stamps its bounded context unchanged.
    * `basis` — `"Mix.Task module <Module>"`, the provenance of the classification.

  Every element is `source: :collected` and carries a stable `task:<name>` id
  (never a file or line), matching the `kind:<canonical-name>` id rule the sibling
  collectors follow. Elements are de-duplicated by id and sorted by it.
  """

  alias ArchLens.Edge
  alias ArchLens.Generator.Scan

  @doc """
  The `:task` entry-point elements for the app's Mix tasks.

  Reads `:mix_task_modules` (an explicit module list) when given, else scans the
  `:app`'s lib-only production modules. Returns `[]` when neither is available.
  """
  @spec collect(keyword()) :: [map()]
  def collect(opts \\ []) do
    opts |> task_modules() |> from_modules()
  end

  @doc """
  Fold Mix task `modules` into sorted `:task` entry-point elements.

  Pure: `collect/1` is this applied to the scanned/explicit module list. A module
  that is not a `Mix.Task` (no `Mix.Task` behaviour) contributes nothing.
  """
  @spec from_modules([module()]) :: [map()]
  def from_modules(modules) do
    modules
    |> Enum.filter(&Scan.mix_task_module?/1)
    |> Enum.map(&element/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp task_modules(opts) do
    cond do
      Keyword.has_key?(opts, :mix_task_modules) ->
        Keyword.get(opts, :mix_task_modules, [])

      app = Keyword.get(opts, :app) ->
        Scan.mix_tasks(app)

      true ->
        []
    end
  end

  defp element(module) do
    name = Mix.Task.task_name(module)
    handler = Edge.module_name(module)

    %{
      id: "task:" <> name,
      kind: :task,
      source: :collected,
      command: "mix " <> name,
      handler: handler,
      basis: "Mix.Task module " <> handler
    }
    |> maybe_put(:description, Mix.Task.shortdoc(module))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
