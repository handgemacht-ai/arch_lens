defmodule ArchLens.Generator.Retention do
  @moduledoc """
  Classifies a resource's declared retention as *enforced* or
  *declared-not-enforced*.

  A retention string on its own is only a claim. It is `:enforced` when the
  codebase actually acts on it: the resource carries an expiry timestamp
  attribute *and* the scanned scope contains a cleanup mechanism — an
  `:oban_insert` edge whose `metadata[:retention_cleanup_for]` names the resource
  — that deletes/expires the data. A retention stated in prose with no such field
  and mechanism is `:declared_not_enforced`.

  The generator renders the two differently, so a policy nothing enforces can
  never masquerade as an enforced one. Everything read here is compiled module
  metadata (attributes, recorded edges); no database is touched.
  """

  alias ArchLens.Edge
  alias ArchLens.Privacy.Info

  # Attribute names conventionally used to carry a per-row expiry the cleanup
  # code acts on. Kept as a fixed, sorted set so classification is deterministic.
  @expiry_attribute_names ~w(
    delete_after
    deleted_at
    expire_at
    expires_at
    purge_after
    purge_at
    retention_until
  )a

  @type label :: :enforced | :declared_not_enforced | :none

  @type evidence :: %{
          optional(:field) => atom(),
          optional(:cleanup) => module() | mfa() | term()
        }

  @doc """
  Classifies `resource` given the scope's `edges`.

  Returns `{:none, %{}}` for a resource with no retention declared, otherwise
  `{:enforced, evidence}` or `{:declared_not_enforced, evidence}` where the
  evidence names the field and/or cleanup mechanism found (or absent).
  """
  @spec classify(module(), [Edge.t()]) :: {label(), evidence()}
  def classify(resource, edges) do
    if Info.retention(resource) do
      field = expiry_attribute(resource)
      cleanup = cleanup_mechanism(resource, edges)

      evidence =
        %{}
        |> maybe_put(:field, field)
        |> maybe_put(:cleanup, cleanup)

      if field && cleanup do
        {:enforced, evidence}
      else
        {:declared_not_enforced, evidence}
      end
    else
      {:none, %{}}
    end
  end

  defp expiry_attribute(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
    |> Enum.filter(&(&1 in @expiry_attribute_names))
    |> Enum.sort_by(&Atom.to_string/1)
    |> List.first()
  rescue
    _ -> nil
  end

  defp cleanup_mechanism(resource, edges) do
    edges
    |> Enum.filter(&cleanup_for?(&1, resource))
    |> Enum.map(& &1.builder)
    |> Enum.sort_by(&inspect/1)
    |> List.first()
  end

  defp cleanup_for?(%Edge{kind: :oban_insert, metadata: metadata}, resource) do
    Map.get(metadata, :retention_cleanup_for) == resource
  end

  defp cleanup_for?(_edge, _resource), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
