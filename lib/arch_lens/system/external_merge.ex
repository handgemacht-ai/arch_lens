defmodule ArchLens.System.ExternalMerge do
  @moduledoc """
  Merges the *declared* externals of an `ArchLens.System` module with the
  *collected* external systems into one element per external.

  A declared external collapses with a collected external system when they share an
  identity — the same normalized `target`, or the same stable `id` (declared
  externals derive `external:<slug(name)>`, which the collector already stamps as
  `external:<slug(vendor)>`, so the same third party lines up regardless of which
  side carried a URL). A collapsed element carries *both* evidences
  (`provenance: ["collected", "declared"]`); an external seen from only one side
  keeps that single provenance. Every element carries a stable `id`, so the merged
  `external_systems` array is one coherent, id-keyed schema the diff can key on. The
  result is deterministic: elements are sorted by target, then id, then name.

  When there are no declared externals the collected list is returned untouched, so
  a scope with no `ArchLens.System` renders byte-identically to before.
  """

  @doc "Merge `collected` external systems with `declared` externals."
  @spec merge([map()], [map()]) :: [map()]
  def merge(collected, []), do: collected

  def merge(collected, declared) do
    declared_key_set = declared |> Enum.flat_map(&declared_keys/1) |> MapSet.new()
    collected_key_set = collected |> Enum.flat_map(&collected_keys/1) |> MapSet.new()

    declared_elements =
      Enum.map(declared, fn external ->
        declared_element(external, intersects?(declared_keys(external), collected_key_set))
      end)

    collected_only =
      collected
      |> Enum.reject(&intersects?(collected_keys(&1), declared_key_set))
      |> Enum.map(&collected_element/1)

    Enum.sort_by(declared_elements ++ collected_only, &sort_key/1)
  end

  defp declared_element(external, also_collected?) do
    %{
      id: declared_id(external),
      name: external[:name],
      via: external[:via],
      target: external[:target],
      does: external[:does],
      source: if(also_collected?, do: "collected", else: "declared"),
      provenance: if(also_collected?, do: ["collected", "declared"], else: ["declared"]),
      label: declared_label(external)
    }
  end

  defp collected_element(entry) do
    entry
    |> Map.put_new(:id, collected_id(entry))
    |> Map.put_new(:source, "collected")
    |> Map.put_new(:provenance, ["collected"])
    |> Map.put_new(:label, collected_label(entry))
  end

  # --- identity ---------------------------------------------------------------

  defp intersects?(keys, key_set), do: Enum.any?(keys, &MapSet.member?(key_set, &1))

  defp declared_keys(external) do
    ["id:" <> declared_id(external) | target_keys(external[:target])]
  end

  defp collected_keys(entry) do
    ["id:" <> collected_id(entry) | target_keys(read(entry, :target))]
  end

  defp target_keys(target) do
    case target_key(target) do
      "" -> []
      key -> ["tgt:" <> key]
    end
  end

  defp declared_id(external), do: "external:" <> slug(external[:name])

  defp collected_id(entry) do
    read(entry, :id) || "external:" <> slug(read(entry, :vendor) || collected_label(entry))
  end

  # Mirrors ArchLens.Collect.Externals' slug so a declared external and the
  # collected external for the same vendor resolve to the same stable id.
  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp declared_label(external) do
    "#{external[:name]} → #{external[:target]} (#{external[:via]})"
  end

  defp collected_label(entry) do
    entry[:label] || entry["label"] || to_string(read(entry, :target))
  end

  defp sort_key(element) do
    {target_key(read(element, :target)), to_string(read(element, :id)),
     to_string(read(element, :name))}
  end

  defp target_key(nil), do: ""
  defp target_key(target), do: target |> to_string() |> String.trim_trailing("/")

  defp read(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, to_string(key))
  end

  defp read(_entry, _key), do: nil
end
