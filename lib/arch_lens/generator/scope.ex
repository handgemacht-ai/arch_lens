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
  """

  alias ArchLens.Edge
  alias ArchLens.Generator.Scan
  alias Ash.Domain.Info, as: DomainInfo

  @enforce_keys [:resources]
  defstruct app: nil,
            domains: [],
            domain_resources: [],
            resources: [],
            edges: [],
            oban_workers: []

  @type t :: %__MODULE__{
          app: atom() | nil,
          domains: [module()],
          domain_resources: [module()],
          resources: [module()],
          edges: [Edge.t()],
          oban_workers: [module()]
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

    %__MODULE__{
      app: app,
      domains: domains,
      domain_resources: domain_resources,
      resources: resources,
      edges: edges,
      oban_workers: oban_workers
    }
  end

  defp ash_domains(nil), do: []
  defp ash_domains(app), do: Application.get_env(app, :ash_domains, [])

  defp sort_modules(modules) do
    modules
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end
end
