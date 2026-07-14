defmodule ArchLens.Collect.Boundaries do
  @moduledoc """
  Ingests the app's declared compile-time zones from the hex
  [`boundary`](https://hex.pm/packages/boundary) library into deterministic,
  verbatim boundary elements — the enforced module graph, captured honestly.

  `scan/1` is the host-app seam. It returns

      %{boundaries: [element], errors: [error]}

  mirroring `ArchLens.Collect.Decisions.scan/1`: the clean elements plus a list of
  classification errors the boundaries gate trips on. An app that does not use
  `boundary` (the lib is not loaded, or no module `use`s it) yields
  `%{boundaries: [], errors: []}` — the section is simply absent, never an error.

  ## Reading the boundary model (which API, and why)

  Each boundary is read with `Boundary.Definition.get(module, nil)`, the reader that
  returns the **normalized, declared** boundary spec (`deps`, `exports`,
  `dirty_xrefs`, `check`, `type`) straight from a module's compiled, persisted
  `Boundary` attribute — the same normalized model `Boundary.Mix.View.build/0`
  itself consumes internally (`load_app_boundaries/3`).

  This per-module reader is deliberately chosen over `Boundary.all/1` +
  `Boundary.Mix.View.build/0`. `View.build/0` resolves the *whole current mix
  project* against the boundary **compiler cache** and `Mix.Project` app name.
  arch_lens runs as a *dependency* of the app it reports on (the host threads the
  scan through a wrapper mix task) and its own test suite has no boundary compiler,
  so it cannot rely on either. `Boundary.Definition.get/2` needs neither — it reads
  the on-disk `.beam` attribute — so it is robust in both settings and keeps the
  scan DB-free / load-only. A `use Boundary, classify_to: Host` module (e.g. a Mix
  task folded into a host boundary) returns `nil` and is correctly not surfaced as
  its own boundary.

  Discovery is the lib-only scan (`ArchLens.Generator.Scan.app_modules/1`), so only
  boundaries declared in the app's `lib/` are reported and dev/test generation
  stays byte-identical.

  ## Sanctioned vs grandfathered classification (structured, never inferred)

  A boundary's `exports` are its public API beyond the front door. The
  sanctioned-public-API vs grandfathered-debt distinction is an *app decision* that
  must be machine-readable — never inferred from source comments. The app declares
  it with `config :arch_lens, :boundary_classifications`, a map keyed by boundary
  module:

      config :arch_lens, :boundary_classifications, %{
        MyApp.Engine => [
          sanctioned: [
            {MyApp.Engine.Container, "run & container artifacts sub-API"}
          ],
          grandfathered: [MyApp.Engine.Enums]
        ]
      }

  Each classification is validated against the boundary's **actual** exports:

    * a `:sanctioned` entry is `{export_module, reason}` — the reason is required
      (a non-blank string), so every sanctioned export carries its rationale;
    * a `:grandfathered` entry is a bare `export_module` — listed, not reasoned;
    * a classified module that is **not** an actual export → a loud error
      (`:unknown_export`); a classification under a module that is not a boundary →
      `:unknown_boundary`; a module classified both ways → `:conflicting`;
    * an actual export with **no** classification is reported as `unclassified` —
      surfaced honestly in the artifact, never guessed into a group.

  Errors are collected (not raised here) and fed to the boundaries gate, which
  fails generation naming each offender. The escape hatch is
  `config :arch_lens, :boundaries, false` (threaded as `enabled: false`), which
  skips ingestion entirely — the section is absent and nothing is validated.
  """

  alias ArchLens.Edge
  alias ArchLens.Generator.Scan

  @type error ::
          {:unknown_boundary, String.t()}
          | {:unknown_export, String.t(), String.t()}
          | {:missing_reason, String.t(), String.t()}
          | {:conflicting, String.t(), String.t()}

  @type result :: %{boundaries: [map()], errors: [error()]}

  @doc """
  Scan the app's declared boundaries into `%{boundaries: [...], errors: [...]}`.

  Options:

    * `:app` — the OTP app whose lib-only modules are scanned for boundaries.
    * `:boundary_modules` — an explicit module list (test escape hatch) bypassing
      the scan.
    * `:classifications` — the sanctioned/grandfathered map (default `%{}`).
    * `:enabled` — `false` disables ingestion (returns the empty result); this is
      the `config :arch_lens, :boundaries, false` escape hatch.
  """
  @spec scan(keyword()) :: result()
  def scan(opts \\ []) do
    if Keyword.get(opts, :enabled, true) and boundary_loaded?() do
      opts
      |> boundary_modules()
      |> build(classifications(opts))
    else
      empty()
    end
  end

  defp empty, do: %{boundaries: [], errors: []}

  defp boundary_loaded? do
    Code.ensure_loaded?(Boundary.Definition) and
      function_exported?(Boundary.Definition, :get, 2)
  end

  defp classifications(opts) do
    case Keyword.get(opts, :classifications, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp boundary_modules(opts) do
    cond do
      mods = Keyword.get(opts, :boundary_modules) -> mods
      app = Keyword.get(opts, :app) -> Scan.app_modules(app)
      true -> []
    end
  end

  # The `{module, definition}` pairs for the modules that actually declare a
  # boundary (a `classify_to` module returns `nil` and is correctly dropped).
  # `boundary` is an optional (test-only) dependency, so `Boundary.Definition.get/2`
  # is reached through `apply/3` — arch_lens must compile and run with boundary
  # absent, guarded by `boundary_loaded?/0` before this is ever called.
  defp definitions(modules) do
    for module <- Enum.uniq(modules),
        Code.ensure_loaded?(module),
        definition = apply(Boundary.Definition, :get, [module, nil]),
        do: {module, definition}
  end

  defp build(modules, classifications) do
    definitions = definitions(modules)
    names = MapSet.new(definitions, fn {module, _def} -> module end)
    export_index = Map.new(definitions, fn {module, def} -> {module, export_set(def)} end)

    elements =
      definitions
      |> Enum.map(fn {module, def} ->
        element(module, def, Map.get(classifications, module, []))
      end)
      |> Enum.sort_by(& &1.id)

    %{boundaries: elements, errors: validate(classifications, names, export_index)}
  end

  defp element(module, def, class) do
    name = Edge.module_name(module)
    exports = export_set(def)
    {sanctioned, grandfathered} = classified(class, exports)
    classified_mods = MapSet.union(MapSet.new(sanctioned, & &1.mod), MapSet.new(grandfathered))
    unclassified = MapSet.difference(exports, classified_mods)

    %{
      id: "boundary:" <> name,
      name: name,
      source: :collected,
      front_door: name,
      type: Atom.to_string(def.type),
      check: %{in: def.check.in, out: def.check.out},
      deps: deps(def.deps),
      dirty_xrefs: modules_to_names(MapSet.to_list(def.dirty_xrefs)),
      exports: %{
        sanctioned:
          sanctioned
          |> Enum.map(&%{module: Edge.module_name(&1.mod), reason: &1.reason})
          |> Enum.sort_by(& &1.module),
        grandfathered: modules_to_names(grandfathered),
        unclassified: modules_to_names(MapSet.to_list(unclassified))
      }
    }
  end

  # The `{module, mode}` deps, sorted, as `%{module, mode}` maps — mode kept verbatim
  # so a compile-only dep stays distinguishable from a runtime one.
  defp deps(deps) do
    deps
    |> Enum.map(fn {module, mode} ->
      %{module: Edge.module_name(module), mode: Atom.to_string(mode)}
    end)
    |> Enum.sort_by(& &1.module)
  end

  # The classification split for one boundary, keeping only entries that are actual
  # exports (bogus entries are reported as errors by `validate/3`, which aborts
  # generation, so they never reach a rendered artifact). Sanctioned entries keep
  # their reason; grandfathered entries are bare modules.
  defp classified(class, exports) do
    sanctioned =
      for {mod, reason} <- Keyword.get(class, :sanctioned, []),
          MapSet.member?(exports, mod),
          do: %{mod: mod, reason: reason}

    grandfathered =
      for mod <- Keyword.get(class, :grandfathered, []),
          MapSet.member?(exports, mod),
          do: mod

    {sanctioned, grandfathered}
  end

  defp validate(classifications, names, export_index) do
    classifications
    |> Enum.flat_map(fn {boundary, class} ->
      boundary_errors(boundary, class, names, export_index)
    end)
    |> Enum.sort()
  end

  defp boundary_errors(boundary, class, names, export_index) do
    if MapSet.member?(names, boundary) do
      exports = Map.get(export_index, boundary, MapSet.new())
      classification_errors(boundary, class, exports)
    else
      [{:unknown_boundary, Edge.module_name(boundary)}]
    end
  end

  defp classification_errors(boundary, class, exports) do
    sanctioned = Keyword.get(class, :sanctioned, [])
    grandfathered = Keyword.get(class, :grandfathered, [])
    name = Edge.module_name(boundary)

    sanctioned_mods = MapSet.new(sanctioned, fn {mod, _reason} -> mod end)
    grandfathered_mods = MapSet.new(grandfathered)

    Enum.concat([
      for(
        {mod, reason} <- sanctioned,
        not valid_reason?(reason),
        do: {:missing_reason, name, Edge.module_name(mod)}
      ),
      for(
        {mod, _reason} <- sanctioned,
        not MapSet.member?(exports, mod),
        do: {:unknown_export, name, Edge.module_name(mod)}
      ),
      for(
        mod <- grandfathered,
        not MapSet.member?(exports, mod),
        do: {:unknown_export, name, Edge.module_name(mod)}
      ),
      for(
        mod <- MapSet.intersection(sanctioned_mods, grandfathered_mods),
        do: {:conflicting, name, Edge.module_name(mod)}
      )
    ])
  end

  defp valid_reason?(reason), do: is_binary(reason) and String.trim(reason) != ""

  # A boundary's exports as a MapSet of root module atoms. An export may be a bare
  # module or a `{module, except: [...]}` subtree spec; both are keyed by their root
  # module (the subtree's `except` refinement is not part of the front-door API
  # classification and is dropped for leanness).
  defp export_set(def) do
    def.exports
    |> Enum.map(&export_module/1)
    |> MapSet.new()
  end

  defp export_module({module, _opts}) when is_atom(module), do: module
  defp export_module(module) when is_atom(module), do: module

  defp modules_to_names(modules) do
    modules |> Enum.map(&Edge.module_name/1) |> Enum.sort()
  end
end
