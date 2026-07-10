defmodule ArchLens.Generator.Scope do
  @moduledoc """
  The resolved, deterministic input the generator renders from.

  A scope is the union of:

    * the resources reachable from the consuming app's Ash domains, and
    * the resources found by a plain module scan (`ArchLens.Generator.Scan`),

  plus the recorded architectural edges and Oban workers. Unioning the two
  resource sources is what lets a domain-unregistered resource (an embedded
  resource, say) still appear in the inventory.

  Every collection is sorted by a stable key here, so a scope built twice from
  unchanged code is identical and the rendered document is byte-stable.

  Options (all optional; sensible, DB-free defaults derived from `:app`):

    * `:app` — the OTP application to scan.
    * `:domains` — Ash domains; defaults to `config :app, ash_domains: [...]`.
    * `:scanned_resources` — module-scan result; defaults to
      `Scan.ash_resources(app)`.
    * `:edges` — recorded edges; defaults to `ArchLens.Edge.Registry.all/0`.
    * `:oban_workers` — Oban workers; defaults to `Scan.oban_workers(app)`.

  The `runtime_components` and `external_systems` fields are seams for the
  follow-up slices. They default to empty and are collected in the host app's
  context (via wrapper mix tasks), so `resolve/1` only reads whatever the caller
  passes for them — it does not scan for them here.

  `entry_points` is a wired seam: pass `:entry_points` directly, or pass `:router`
  (a host Phoenix router module) and `resolve/1` collects the entry points from it
  via `ArchLens.Collect.EntryPoints.collect/1`. This mirrors how `:edges` defaults
  to the recorded registry — an explicit value always wins.

  `declared_architecture` is the other wired seam: pass `:declared_architecture`
  directly, or pass `:system` (a module that `use ArchLens.System`) and `resolve/1`
  reads its actors/externals/contexts, validates them against the already-collected
  `entry_points`/`external_systems` (`ArchLens.System.Declared`), and puts the
  validated value on `declared_architecture`. An invalid declaration raises
  `ArchLens.System.ValidationError` — generation fails rather than emitting a lie.
  """

  alias ArchLens.Collect
  alias ArchLens.Edge
  alias ArchLens.Generator.Scan
  alias ArchLens.System.Declared
  alias Ash.Domain.Info, as: DomainInfo

  @enforce_keys [:resources]
  defstruct app: nil,
            domains: [],
            domain_resources: [],
            resources: [],
            edges: [],
            oban_workers: [],
            entry_points: [],
            runtime_components: [],
            external_systems: [],
            declared_architecture: []

  @type t :: %__MODULE__{
          app: atom() | nil,
          domains: [module()],
          domain_resources: [module()],
          resources: [module()],
          edges: [Edge.t()],
          oban_workers: [module()],
          entry_points: [term()],
          runtime_components: [term()],
          external_systems: [term()],
          declared_architecture: [term()]
        }

  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    app = Keyword.get(opts, :app)
    domains = opts |> Keyword.get_lazy(:domains, fn -> ash_domains(app) end) |> sort_modules()

    domain_resources =
      domains
      |> Enum.flat_map(&DomainInfo.resources/1)
      |> sort_modules()

    scanned = Keyword.get_lazy(opts, :scanned_resources, fn -> Scan.ash_resources(app) end)

    resources = sort_modules(domain_resources ++ scanned)

    edges = Keyword.get_lazy(opts, :edges, fn -> Edge.Registry.all() end)

    oban_workers =
      opts
      |> Keyword.get_lazy(:oban_workers, fn -> Scan.oban_workers(app) end)
      |> sort_modules()

    entry_points = Keyword.get_lazy(opts, :entry_points, fn -> collect_entry_points(opts) end)
    external_systems = Keyword.get(opts, :external_systems, [])

    %__MODULE__{
      app: app,
      domains: domains,
      domain_resources: domain_resources,
      resources: resources,
      edges: edges,
      oban_workers: oban_workers,
      entry_points: entry_points,
      runtime_components: Keyword.get(opts, :runtime_components, []),
      external_systems: external_systems,
      declared_architecture:
        declared_architecture(
          opts,
          app,
          resources,
          oban_workers,
          edges,
          entry_points,
          external_systems
        )
    }
  end

  defp collect_entry_points(opts) do
    case Keyword.get(opts, :router) do
      nil -> []
      router -> Collect.EntryPoints.collect(router)
    end
  end

  defp declared_architecture(
         opts,
         app,
         resources,
         oban_workers,
         edges,
         entry_points,
         external_systems
       ) do
    case Keyword.get(opts, :system) do
      nil ->
        Keyword.get(opts, :declared_architecture, [])

      system ->
        Declared.resolve!(system, %{
          app: app,
          resources: resources,
          oban_workers: oban_workers,
          edges: edges,
          entry_points: entry_points,
          external_systems: external_systems,
          vendors: Keyword.get(opts, :vendors),
          known_modules: Keyword.get(opts, :known_modules)
        })
    end
  end

  defp ash_domains(nil), do: []
  defp ash_domains(app), do: Application.get_env(app, :ash_domains, [])

  defp sort_modules(modules) do
    modules
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end
end
