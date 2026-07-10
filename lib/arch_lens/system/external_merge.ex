defmodule ArchLens.System.ExternalMerge do
  @moduledoc """
  Merges the *declared* externals of an `ArchLens.System` module with the
  *collected* external systems into one element per external.

  A declared external whose target matches a collected external system's target
  collapses into a single element carrying *both* evidences
  (`provenance: ["collected", "declared"]`); an external seen from only one side
  keeps that single provenance. The result is deterministic: elements are sorted by
  target then name.

  When there are no declared externals the collected list is returned untouched, so
  a scope with no `ArchLens.System` renders byte-identically to before.
  """

  @doc "Merge `collected` external systems with `declared` externals."
  @spec merge([map()], [map()]) :: [map()]
  def merge(collected, []), do: collected

  def merge(collected, declared) do
    collected_by_target =
      Map.new(collected, fn entry -> {target_key(read(entry, :target)), entry} end)

    matched_keys =
      declared
      |> Enum.map(&target_key(&1[:target]))
      |> Enum.filter(&Map.has_key?(collected_by_target, &1))
      |> MapSet.new()

    declared_elements =
      Enum.map(declared, fn external ->
        also_collected? = Map.has_key?(collected_by_target, target_key(external[:target]))
        declared_element(external, also_collected?)
      end)

    collected_only =
      collected
      |> Enum.reject(&MapSet.member?(matched_keys, target_key(read(&1, :target))))
      |> Enum.map(&collected_element/1)

    Enum.sort_by(declared_elements ++ collected_only, &sort_key/1)
  end

  defp declared_element(external, also_collected?) do
    %{
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
    |> Map.put_new(:source, "collected")
    |> Map.put_new(:provenance, ["collected"])
    |> Map.put_new(:label, collected_label(entry))
  end

  defp declared_label(external) do
    "#{external[:name]} → #{external[:target]} (#{external[:via]})"
  end

  defp collected_label(entry) do
    entry[:label] || entry["label"] || to_string(read(entry, :target))
  end

  defp sort_key(element) do
    {target_key(read(element, :target)), to_string(read(element, :name))}
  end

  defp target_key(nil), do: ""
  defp target_key(target), do: target |> to_string() |> String.trim_trailing("/")

  defp read(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, to_string(key))
  end

  defp read(_entry, _key), do: nil
end
