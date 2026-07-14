defmodule ArchLens.Generator.Scan do
  @moduledoc """
  DB-free discovery of the *production* modules the generator reports on.

  Enumerates an OTP application's compiled module list (read from its `.app`
  metadata via `:application.get_key/2`, never a database) and filters it down to
  the modules whose compiled source lives under the project's `lib/` directory —
  the app's production code. Ash resources and Oban workers are then selected from
  that production set.

  ## Why lib-only

  Under `MIX_ENV=test` a host app compiles extra `elixirc_paths` (typically
  `test/support`) into the *same* OTP application, so `:application.get_key/2`
  returns those test-support modules alongside the real `lib/` modules. Left
  unfiltered they leak into architecture discovery and the generation gates: a
  `test/support` module shaped like a context (a `@moduledoc` on a directory root,
  with children) surfaces as a bounded context, and an Ash resource defined in
  `test/support` surfaces in the inventory — present under `:test` but absent under
  `:dev`. The generated artifact then differs by environment, which permanently
  trips the `--check` staleness gate in CI (dev-generated committed artifacts never
  carry the test-only content).

  Restricting the scan to modules whose compiled source is under `lib/` makes the
  scan — and therefore every artifact and every gate derived from it — environment
  independent: the module set is identical whether generation runs under `:dev` or
  `:test`, because the only modules the two environments disagree on are exactly the
  extra `elixirc_paths` this filter removes.

  A module whose compiled source cannot be resolved (no `:source` in its compile
  metadata, or it cannot be loaded) is treated as non-production and excluded; a
  genuine `lib/` module always carries a source, so this only drops synthetic or
  dynamically-defined modules that have no place in an architecture inventory.

  The lib-only boundary is applied at this app-scan seam only. Explicitly supplied
  module lists (`ash_resources_from_modules/1`, `oban_workers_from_modules/1`, and
  the `:modules`/`:scanned_resources`/`:oban_workers` overrides on
  `ArchLens.Generator.Scope`) are trusted as-is — the caller owns that scope.

  The plain module scan is deliberately independent of any domain's `resources`
  block. A resource that is *embedded* in another resource — and therefore absent
  from every domain's resource list — is still discovered here, which is why the
  generator unions this scan against the domain resources rather than trusting the
  domains alone.
  """

  alias ArchLens.Edge.Registry
  alias Ash.Resource.Info, as: ResourceInfo

  @doc """
  Every Ash resource in `app`'s production code (`lib/`), sorted by module name.

  `nil` yields an empty list so callers can pass an unresolved app without a
  guard.
  """
  @spec ash_resources(atom() | nil) :: [module()]
  def ash_resources(nil), do: []

  def ash_resources(app) when is_atom(app) do
    app |> app_modules() |> ash_resources_from_modules()
  end

  @doc """
  Filters an explicit module list down to the Ash resources it contains, sorted
  by module name and de-duplicated. Pure: `ash_resources/1` is this applied to an
  app's module list.
  """
  @spec ash_resources_from_modules([module()]) :: [module()]
  def ash_resources_from_modules(modules) do
    modules
    |> Enum.filter(&ash_resource?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  @doc """
  Every Oban worker in `app`'s production code (`lib/`), sorted by module name.

  Always empty when Oban is not loadable, so a scanned app with Oban absent — or
  present but with zero jobs registered — renders cleanly.
  """
  @spec oban_workers(atom() | nil) :: [module()]
  def oban_workers(nil), do: []

  def oban_workers(app) when is_atom(app) do
    app |> app_modules() |> oban_workers_from_modules()
  end

  @doc "Filters an explicit module list down to the Oban workers it contains."
  @spec oban_workers_from_modules([module()]) :: [module()]
  def oban_workers_from_modules(modules) do
    if Registry.oban_available?() do
      modules
      |> Enum.filter(&oban_worker?/1)
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)
    else
      []
    end
  end

  @doc """
  Every Mix task in `app`'s production code (`lib/`), sorted by module name.

  A Mix task is a `Mix.Tasks.*` module that `use`s `Mix.Task`. Discovery runs
  through the same lib-only scan as resources and Oban workers, so a task compiled
  only from `test/support` stays honestly out of scope. `nil` yields an empty list.
  """
  @spec mix_tasks(atom() | nil) :: [module()]
  def mix_tasks(nil), do: []

  def mix_tasks(app) when is_atom(app) do
    app |> app_modules() |> mix_tasks_from_modules()
  end

  @doc "Filters an explicit module list down to the Mix task modules it contains."
  @spec mix_tasks_from_modules([module()]) :: [module()]
  def mix_tasks_from_modules(modules) do
    modules
    |> Enum.filter(&mix_task_module?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  @doc """
  Whether `module` is an invokable Mix task: a `Mix.Tasks.*` module that carries
  the `Mix.Task` behaviour and exports `run/1`. The `Mix.Tasks.` prefix is required
  so `Mix.Task.task_name/1` derives a correct task name from the module.
  """
  @spec mix_task_module?(module()) :: boolean()
  def mix_task_module?(module) when is_atom(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Mix.Tasks.") and
      Code.ensure_loaded?(module) and
      function_exported?(module, :run, 1) and
      behaviour?(module, Mix.Task)
  end

  def mix_task_module?(_module), do: false

  @doc """
  Every *production* module compiled into `app` — the modules whose compiled source
  lives under the project's `lib/` directory — read from the app's `.app` metadata
  (never a database) and filtered to `lib/`. See the moduledoc for why the scan is
  lib-only. `nil` yields an empty list.
  """
  @spec app_modules(atom() | nil) :: [module()]
  def app_modules(nil), do: []

  def app_modules(app) when is_atom(app) do
    app |> loaded_modules() |> lib_only()
  end

  @doc """
  Keeps only the *production* modules in `modules`: those whose compiled source
  lives under `lib_root` (defaulting to the current project's `lib/` directory,
  `Path.expand("lib", File.cwd!())`). A module with no resolvable compiled source is
  excluded. See the moduledoc for the environment-independence rationale.

  For a nested-root project (the Mix project lives in a subdirectory, e.g.
  eval-lab's `app/`), `File.cwd!()` is that subdirectory when generation runs, so
  the default `lib_root` is `<subdir>/lib` — the correct production root.
  """
  @spec lib_only([module()], String.t()) :: [module()]
  def lib_only(modules, lib_root \\ project_lib_root()) do
    Enum.filter(modules, &under_lib?(&1, lib_root))
  end

  # The raw compiled module list from the app's `.app` metadata, before the
  # lib-only production filter. Under MIX_ENV=test this includes the extra
  # elixirc_paths (test/support) compiled into the same application.
  defp loaded_modules(app) do
    _ = Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end

  defp under_lib?(module, lib_root) do
    case module_source(module) do
      nil -> false
      source -> String.starts_with?(source, lib_root <> "/")
    end
  end

  defp module_source(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         source when is_list(source) or is_binary(source) <-
           module.__info__(:compile)[:source] do
      source |> to_string() |> Path.expand()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp module_source(_), do: nil

  defp project_lib_root, do: Path.expand("lib", File.cwd!())

  defp ash_resource?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and ResourceInfo.resource?(module)
  end

  defp ash_resource?(_), do: false

  defp oban_worker?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :perform, 1) and
      behaviour?(module, Oban.Worker)
  end

  defp oban_worker?(_), do: false

  defp behaviour?(module, behaviour) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  rescue
    _ -> false
  end
end
