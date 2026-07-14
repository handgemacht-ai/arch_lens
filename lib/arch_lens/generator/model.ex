defmodule ArchLens.Generator.Model do
  @moduledoc """
  The single, deterministic intermediate both artifacts render from.

  `to_map/1` folds a resolved `ArchLens.Generator.Scope` into an ordered, plain map
  — a `schema_version`, the `app` identity, the resource privacy inventory, the
  merged architectural edges, the Oban workers (with queue/cron), the cross-context
  `context_dependencies`, the declared `flows`, the derived `data_inventory`, the
  indexed `decisions`, and the follow-up-slice seams (entry points, runtime
  components, external systems, declared architecture). Markdown
  (`ArchLens.Generator.Document`) and JSON (`encode/1`) are both produced from this
  one map, so the two committed artifacts can never disagree.

  Every element carries a `source`: `"declared"` for things a human asserted
  (privacy postures, declared architecture), `"collected"` for things scanned out
  of the code (edges, Oban workers). Retention is structured
  (`%{policy, enforcement, …}`) via `ArchLens.Generator.Retention.classify/2`, not
  just the prose policy string.

  Determinism is the contract: every collection is sorted by a stable key, call-site
  paths are repo-relativised, and no wall-clock timestamp, git SHA, or absolute path
  is emitted. `encode/1` sorts object keys, so generating twice from unchanged code
  is byte-identical.
  """

  alias ArchLens.Collect.ModuleDoc
  alias ArchLens.Domain
  alias ArchLens.Edge

  alias ArchLens.Generator.{
    Attribution,
    ContextEdges,
    Contexts,
    Flows,
    Namespace,
    Paths,
    Retention,
    Scope,
    Section
  }

  alias ArchLens.Generator.Sections.{
    Boundaries,
    Decisions,
    DeclaredArchitecture,
    EntryPoints,
    ExternalSystems,
    RuntimeComponents
  }

  alias ArchLens.Privacy.{Declaration, Info}
  alias ArchLens.System.ExternalMerge

  @schema_version 3

  @doc "The model schema version stamped into every artifact."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Fold `scope` into the deterministic intermediate map."
  @spec to_map(Scope.t()) :: map()
  def to_map(%Scope{} = scope) do
    %{contexts: contexts} = Contexts.resolve(scope)
    context_index = Namespace.context_index(scope, contexts)

    %{
      schema_version: @schema_version,
      app: app_map(scope),
      resources: Enum.map(scope.resources, &resource_map(&1, scope)),
      edges: scope.edges |> Enum.sort_by(&Edge.sort_key/1) |> Enum.map(&edge_map/1),
      oban_workers: Enum.map(scope.oban_workers, &oban_worker_map(&1, scope)),
      entry_points:
        scope.entry_points |> Attribution.attribute(contexts) |> EntryPoints.to_json(),
      runtime_components: RuntimeComponents.to_json(scope.runtime_components),
      external_systems: ExternalSystems.to_json(external_entries(scope)),
      context_dependencies: ContextEdges.build(scope.dependency_refs, context_index),
      flows: Flows.resolve(scope),
      data_inventory: data_inventory(scope),
      decisions: Decisions.to_json(scope.decisions),
      declared_architecture: DeclaredArchitecture.to_json(declared_architecture(scope, contexts))
    }
    |> maybe_put(:boundaries, boundaries_json(scope))
  end

  # The boundaries section is conditionally present: absent (the key is dropped)
  # when the app does not use the hex `boundary` library, so an already-committed
  # artifact stays byte-identical until the app adopts boundaries. This is additive
  # and keeps `schema_version` at 3 — the same rule the entry-point and decisions
  # seams follow — so cross-version diffs against pre-boundaries artifacts still work.
  defp boundaries_json(%Scope{boundaries: []}), do: nil
  defp boundaries_json(%Scope{boundaries: boundaries}), do: Boundaries.to_json(boundaries)

  # The declared-architecture value the section renders: the central actors and
  # validation warnings (unchanged), but with contexts resolved from in-place
  # annotations (`ArchLens.Generator.Contexts`, resolved once in `to_map/1` and
  # threaded here). A plain legacy list with nothing to resolve is passed through
  # untouched for backward compatibility.
  defp declared_architecture(%Scope{declared_architecture: central}, contexts) do
    if is_list(central) and contexts == [] do
      central
    else
      %{
        actors: declared_field(central, :actors),
        contexts: contexts,
        warnings: declared_field(central, :warnings)
      }
    end
  end

  defp declared_field(central, key) when is_map(central), do: Map.get(central, key, [])
  defp declared_field(_central, _key), do: []

  defp external_entries(%Scope{} = scope) do
    ExternalMerge.merge(
      scope.external_systems,
      declared_externals(scope.declared_architecture),
      ignore_externals: scope.ignore_externals,
      deps: scope.deps
    )
  end

  defp declared_externals(%{externals: externals}) when is_list(externals), do: externals
  defp declared_externals(_declared), do: []

  @doc "The deterministic JSON string for `scope` (via `to_map/1`)."
  @spec to_json(Scope.t()) :: String.t()
  def to_json(%Scope{} = scope), do: scope |> to_map() |> encode()

  @doc """
  Encode an already-built model map to a deterministic, key-sorted, pretty JSON
  string terminated by a single newline.
  """
  @spec encode(map()) :: String.t()
  def encode(model) when is_map(model) do
    (model |> ordered() |> Jason.encode!(pretty: true)) <> "\n"
  end

  defp resource_map(resource, %Scope{} = scope) do
    name = Edge.module_name(resource)

    %{
      id: "res:" <> name,
      module: name,
      source: "declared",
      discovered_via_scan: resource not in scope.domain_resources,
      privacy: privacy_map(resource, scope.edges)
    }
    |> maybe_put(:doc, ModuleDoc.first_paragraph(resource))
  end

  defp privacy_map(resource, edges) do
    case Info.posture(resource) do
      %Declaration{} = declaration ->
        %{
          posture: "declared",
          legal_basis: declaration.legal_basis,
          retention: retention_map(resource, edges)
        }
        |> Map.merge(category_field(declaration))

      :no_personal_data ->
        %{posture: "no_personal_data"}

      {:exempt, reason} ->
        %{posture: "exempt", reason: reason}

      :undeclared ->
        %{posture: "undeclared"}
    end
  end

  # The privacy category surface. A v3 declaration carries a `categories` list; a
  # legacy declaration carries the deprecated singular `data_category` atom, which
  # is rendered verbatim under its own key so already-adopted resources stay
  # byte-stable until they migrate. Exactly one of the two is present.
  defp category_field(%Declaration{categories: categories}) when is_list(categories) do
    %{categories: sorted_category_strings(categories)}
  end

  defp category_field(%Declaration{data_category: category}) when not is_nil(category) do
    %{data_category: category}
  end

  defp category_field(_declaration), do: %{}

  defp retention_map(resource, edges) do
    {label, evidence} = Retention.classify(resource, edges)

    %{policy: Info.retention(resource), enforcement: Atom.to_string(label)}
    |> maybe_put(:field, evidence[:field])
    |> maybe_put(:cleanup, evidence[:cleanup] && Edge.canonical_builder(evidence[:cleanup]))
  end

  defp edge_map(%Edge{} = edge) do
    %{
      id: Edge.id(edge),
      kind: edge.kind,
      source: "collected",
      builder: Edge.canonical_builder(edge.builder),
      target: edge_target(edge.target),
      call_sites: call_sites_map(edge.call_sites),
      metadata: Section.jsonable(edge.metadata)
    }
  end

  defp edge_target(nil), do: nil
  defp edge_target(target), do: Edge.canonical_target(target)

  defp call_sites_map(sites) do
    sites
    |> Enum.map(fn {file, line} -> %{file: Paths.relativize(file), line: line} end)
    |> Enum.sort_by(fn %{file: file, line: line} -> {file, line} end)
  end

  # An Oban worker element, enriched with its `queue` (from the compiled
  # `Oban.Worker.__opts__/0`, default `"default"` — DB-free, no app start) and the
  # `cron` schedules that trigger it (joined from `scope.cron`, fed by the cron
  # collector; `[]` when the worker is only enqueued in code).
  defp oban_worker_map(module, %Scope{cron: cron}) do
    name = Edge.module_name(module)

    %{
      id: "oban:" <> name,
      module: name,
      source: "collected",
      queue: worker_queue(module),
      cron: Map.get(cron, module, [])
    }
    |> maybe_put(:doc, ModuleDoc.first_paragraph(module))
  end

  defp worker_queue(module) do
    if function_exported?(module, :__opts__, 0) do
      module.__opts__() |> Keyword.get(:queue, :default) |> to_string()
    else
      "default"
    end
  end

  # The per-app identity block: the declared town identity when present, else the
  # OTP app name (`source: "collected"`). `id` is always present.
  defp app_map(%Scope{declared_architecture: %{identity: identity}}) when is_map(identity) do
    %{id: to_string(Map.get(identity, :id)), source: "declared"}
    |> maybe_put(:name, Map.get(identity, :name))
    |> maybe_put(:aliases, present_list(Map.get(identity, :aliases)))
  end

  defp app_map(%Scope{app: nil}), do: %{id: "app", source: "collected"}
  defp app_map(%Scope{app: app}), do: %{id: to_string(app), source: "collected"}

  # The DERIVED data inventory: each in-scope resource joined to its bounded
  # context (via its Ash domain, else the synthetic `"(unassigned)"` bucket),
  # grouped and sorted deterministically. Introduces no new source of truth — every
  # category and posture is verbatim from the resource's own privacy declaration.
  defp data_inventory(%Scope{resources: resources}) do
    resources
    |> Enum.map(&inventory_row/1)
    |> Enum.group_by(&{&1.context, &1.context_source}, & &1.resource)
    |> Enum.map(fn {{context, source}, rows} ->
      sorted = Enum.sort_by(rows, & &1.module)

      %{
        context: context,
        context_source: source,
        resources: sorted,
        categories: sorted |> Enum.flat_map(& &1.categories) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.context)
  end

  defp inventory_row(module) do
    {context, source} = resource_context(module)
    {posture, categories} = resource_posture(module)

    %{
      context: context,
      context_source: source,
      resource: %{module: Edge.module_name(module), posture: posture, categories: categories}
    }
  end

  defp resource_context(module) do
    case Ash.Resource.Info.domain(module) do
      nil -> {"(unassigned)", "unassigned"}
      domain -> {to_string(Domain.name(domain)), "domain"}
    end
  end

  defp resource_posture(module) do
    case Info.posture(module) do
      %Declaration{} = declaration -> {"declared", declaration_categories(declaration)}
      :no_personal_data -> {"no_personal_data", []}
      {:exempt, _reason} -> {"exempt", []}
      :undeclared -> {"undeclared", []}
    end
  end

  defp declaration_categories(%Declaration{categories: categories}) when is_list(categories),
    do: sorted_category_strings(categories)

  defp declaration_categories(%Declaration{data_category: category}) when not is_nil(category),
    do: [to_string(category)]

  defp declaration_categories(_declaration), do: []

  defp sorted_category_strings(categories) do
    categories |> Enum.map(&to_string/1) |> Enum.sort()
  end

  defp present_list(list) when is_list(list) and list != [], do: list
  defp present_list(_other), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Recursively sort object keys so encoding is order-independent and byte-stable,
  # regardless of Erlang's map iteration order.
  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
