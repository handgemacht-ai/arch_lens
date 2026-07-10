defmodule ArchLens.Generator.Model do
  @moduledoc """
  The single, deterministic intermediate both artifacts render from.

  `to_map/1` folds a resolved `ArchLens.Generator.Scope` into an ordered, plain map
  — a `schema_version`, the resource privacy inventory, the merged architectural
  edges, the Oban workers, and the four follow-up-slice seams. Markdown
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

  alias ArchLens.Edge
  alias ArchLens.Generator.{Paths, Retention, Scope, Section}

  alias ArchLens.Generator.Sections.{
    DeclaredArchitecture,
    EntryPoints,
    ExternalSystems,
    RuntimeComponents
  }

  alias ArchLens.Privacy.{Declaration, Info}
  alias ArchLens.System.ExternalMerge

  @schema_version 1

  @doc "The model schema version stamped into every artifact."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Fold `scope` into the deterministic intermediate map."
  @spec to_map(Scope.t()) :: map()
  def to_map(%Scope{} = scope) do
    %{
      schema_version: @schema_version,
      resources: Enum.map(scope.resources, &resource_map(&1, scope)),
      edges: scope.edges |> Enum.sort_by(&Edge.sort_key/1) |> Enum.map(&edge_map/1),
      oban_workers: Enum.map(scope.oban_workers, &oban_worker_map/1),
      entry_points: EntryPoints.to_json(scope.entry_points),
      runtime_components: RuntimeComponents.to_json(scope.runtime_components),
      external_systems: ExternalSystems.to_json(external_entries(scope)),
      declared_architecture: DeclaredArchitecture.to_json(scope.declared_architecture)
    }
  end

  defp external_entries(%Scope{external_systems: collected, declared_architecture: declared}) do
    ExternalMerge.merge(collected, declared_externals(declared))
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
  end

  defp privacy_map(resource, edges) do
    case Info.posture(resource) do
      %Declaration{data_category: category, legal_basis: basis} ->
        %{
          posture: "declared",
          data_category: category,
          legal_basis: basis,
          retention: retention_map(resource, edges)
        }

      :no_personal_data ->
        %{posture: "no_personal_data"}

      :undeclared ->
        %{posture: "undeclared"}
    end
  end

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

  defp oban_worker_map(module) do
    name = Edge.module_name(module)
    %{id: "oban:" <> name, module: name, source: "collected"}
  end

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
