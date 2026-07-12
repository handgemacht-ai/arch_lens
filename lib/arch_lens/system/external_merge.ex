defmodule ArchLens.System.ExternalMerge do
  @moduledoc """
  Merges the *declared* externals of an `ArchLens.System` module with the
  *collected* external systems into one element per external.

  A declared external collapses with a collected external system when they share an
  identity (`ArchLens.System.ExternalEvidence.matches?/2`): the same stable `id`
  (declared externals derive `external:<slug(name)>`, which the collector already
  stamps as `external:<slug(vendor)>`), the same normalized `target`, or the same
  target host — so one clean `external(target: host)` declaration collapses an ugly
  host-derived collected vendor. A collapsed element carries the collected
  evidence and `provenance: ["collected", "declared"]`; an external seen from only
  one side keeps that single provenance.

  Every element carries exactly one `verification`, stamped by
  `ArchLens.System.ExternalEvidence.stamp/2`:

    * `corroborated` — declared and backed by collected code evidence or a resolved
      `evidence:` hint (`provenance: ["collected", "declared"]`).
    * `manual` — declared with the `evidence: [manual: "reason"]` escape hatch, no
      code evidence (`provenance: ["declared"]`; the reason is the evidence).
    * `ignored` — collected but not declared, tagged so it still renders rather than
      being silently dropped (`provenance: ["collected"]`). By the time generation
      renders, `ExternalEvidence.gate/1` has already failed any collected external
      that is neither declared nor listed in `ignore_externals`, so a collected-only
      element that reaches here is an ignored one.

  The result is deterministic: elements are sorted by target, then id, then name.
  `merge/3` accepts (and ignores) the `:ignore_externals` and `:deps` options — the
  ignore list is enforced by the completeness gate, and hint resolution by the
  validation gate; the stamp trusts both.
  """

  alias ArchLens.System.ExternalEvidence

  @doc """
  Merge `collected` external systems with `declared` externals, stamping a
  `verification` on each element.
  """
  @spec merge([map()], [map()], keyword()) :: [map()]
  def merge(collected, declared, opts \\ [])

  def merge(collected, [], _opts), do: Enum.map(collected, &collected_element/1)

  def merge(collected, declared, _opts) do
    declared_elements =
      Enum.map(declared, fn external ->
        matched = Enum.find(collected, &ExternalEvidence.matches?(external, &1))
        declared_element(external, matched)
      end)

    collected_only =
      collected
      |> Enum.reject(fn element ->
        Enum.any?(declared, &ExternalEvidence.matches?(&1, element))
      end)
      |> Enum.map(&collected_element/1)

    Enum.sort_by(declared_elements ++ collected_only, &sort_key/1)
  end

  defp declared_element(external, matched) do
    {verification, provenance, evidence} = ExternalEvidence.stamp(external, matched)

    %{
      id: declared_id(external),
      name: external[:name],
      via: external[:via],
      target: external[:target],
      does: external[:does],
      source: if(matched, do: "collected", else: "declared"),
      provenance: provenance,
      verification: verification,
      evidence: evidence,
      label: declared_label(external)
    }
  end

  defp collected_element(entry) do
    entry
    |> Map.put_new(:id, collected_id(entry))
    |> Map.put_new(:source, "collected")
    |> Map.put(:provenance, ["collected"])
    |> Map.put(:verification, "ignored")
    |> Map.put_new(:label, collected_label(entry))
  end

  # --- identity -----------------------------------------------------------------

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
