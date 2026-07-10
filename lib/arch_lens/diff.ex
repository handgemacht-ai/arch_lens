defmodule ArchLens.Diff do
  @moduledoc """
  Diffs two architecture Model maps (`ArchLens.Generator.Model.to_map/1` output, or
  its JSON-decoded form) into a set of stable-ID-keyed deltas.

  Identity is the model's own stable ids — `res:<Module>`, `oban:<Module>`,
  `edge:<kind>:<builder>=><target>`, and the analogous ids future element kinds
  carry — never a file or line. Because an edge's identity already folds in its
  canonical builder and target, changing an edge's target reads as one edge removed
  and another added, not a mutation; the only per-edge mutation left is its
  `call_sites`/`metadata`.

  `compute/2` returns `%{added, removed, changed, location_only}`:

    * `added` / `removed` — elements present on only one side.
    * `changed` — elements present on both whose semantic fields differ, each
      carrying field-level `%{field, before, after}` deltas.
    * `location_only` — elements whose *only* difference is their `call_sites`
      list (the file/line where a boundary is crossed moved, the boundary did
      not). These never enter the headline counts.

  Every delta is severity-classified. A delta is `:warn` when it widens the app's
  data or privacy surface (see `severity` rules below); everything else is `:info`.

  ## Severity (WARN) rules

    1. A new `:http_boundary` edge or a new external system — new data egress.
    2. A resource crossing from `no_personal_data` (or undeclared) into a personal
       `data_category`, or otherwise gaining a personal `data_category`.
    3. A `data_category` value new to the whole system.
    4. A retention-enforcement regression (`enforced` → `declared_not_enforced`),
       or a newly-added personal-data resource without *enforced* retention.

  ## Inputs

  Both maps are canonicalised on the way in (keys stringified, non-boolean atom
  values stringified), so a map straight from `Model.to_map/1` (atom keys, atom
  `data_category`) and the same model round-tripped through JSON compare equal.

  A `nil` baseline means "no baseline existed" (first adoption): every element is
  reported as `added` and `baseline_present: false`. A `schema_version` mismatch
  between two present models raises `ArchLens.Diff.SchemaMismatchError`, since
  deltas across incompatible schemas are meaningless.
  """

  alias ArchLens.Diff.SchemaMismatchError

  @element_groups ~w(
    resources
    edges
    oban_workers
    external_systems
    runtime_components
    entry_points
    declared_architecture
  )

  @type severity :: :warn | :info
  @type change :: :added | :removed | :changed | :location_only

  @type field_delta :: %{field: String.t(), before: term(), after: term()}

  @type delta :: %{
          id: String.t(),
          group: String.t(),
          kind: String.t(),
          change: change(),
          severity: severity(),
          reasons: [atom()],
          source: String.t() | nil,
          changes: [field_delta()],
          location_changes: [field_delta()],
          element: map() | nil
        }

  @type result :: %{
          schema_version: term(),
          baseline_present: boolean(),
          added: [delta()],
          removed: [delta()],
          changed: [delta()],
          location_only: [delta()]
        }

  @doc """
  Diffs `baseline` against `candidate`.

  `baseline` may be `nil` (first adoption — everything is `added`). Raises
  `ArchLens.Diff.SchemaMismatchError` when two present models disagree on
  `schema_version`.
  """
  @spec compute(map() | nil, map()) :: result()
  def compute(nil, candidate) when is_map(candidate) do
    candidate = canonicalize(candidate)
    new_categories = category_set(candidate)

    added =
      candidate
      |> index_elements()
      |> Map.values()
      |> Enum.map(&added_delta(&1, new_categories))
      |> sort_deltas()

    %{
      schema_version: Map.get(candidate, "schema_version"),
      baseline_present: false,
      added: added,
      removed: [],
      changed: [],
      location_only: []
    }
  end

  def compute(baseline, candidate) when is_map(baseline) and is_map(candidate) do
    baseline = canonicalize(baseline)
    candidate = canonicalize(candidate)
    ensure_schema_match!(baseline, candidate)

    base = index_elements(baseline)
    cand = index_elements(candidate)

    new_categories =
      MapSet.difference(category_set(candidate), category_set(baseline))

    base_keys = base |> Map.keys() |> MapSet.new()
    cand_keys = cand |> Map.keys() |> MapSet.new()

    added =
      cand_keys
      |> MapSet.difference(base_keys)
      |> Enum.map(&added_delta(cand[&1], new_categories))
      |> sort_deltas()

    removed =
      base_keys
      |> MapSet.difference(cand_keys)
      |> Enum.map(&removed_delta(base[&1]))
      |> sort_deltas()

    common_deltas =
      base_keys
      |> MapSet.intersection(cand_keys)
      |> Enum.map(&common_delta(base[&1], cand[&1], new_categories))
      |> Enum.reject(&is_nil/1)

    %{
      schema_version: Map.get(candidate, "schema_version"),
      baseline_present: true,
      added: added,
      removed: removed,
      changed: common_deltas |> Enum.filter(&(&1.change == :changed)) |> sort_deltas(),
      location_only: common_deltas |> Enum.filter(&(&1.change == :location_only)) |> sort_deltas()
    }
  end

  @doc "How many `:warn`-severity deltas the result carries."
  @spec warning_count(result()) :: non_neg_integer()
  def warning_count(%{added: added, removed: removed, changed: changed}) do
    Enum.count(added ++ removed ++ changed, &(&1.severity == :warn))
  end

  @doc "Every `:warn`-severity delta across `added`, `removed`, and `changed`, id-sorted."
  @spec warnings(result()) :: [delta()]
  def warnings(%{added: added, removed: removed, changed: changed}) do
    (added ++ removed ++ changed) |> Enum.filter(&(&1.severity == :warn)) |> sort_deltas()
  end

  @doc "Render `result` in `format` (`:json`, `:text`, or `:markdown`)."
  @spec render(result(), :json | :text | :markdown) :: String.t()
  defdelegate render(result, format), to: ArchLens.Diff.Report

  # --- delta construction -------------------------------------------------

  defp added_delta(element, new_categories) do
    reasons = added_reasons(element, new_categories)

    element
    |> base_delta(:added, reasons)
    |> Map.put(:element, element.entry)
  end

  defp removed_delta(element) do
    element
    |> base_delta(:removed, [])
    |> Map.put(:element, element.entry)
  end

  defp common_delta(base_el, cand_el, new_categories) do
    {location, semantic} =
      base_el.entry
      |> diff_fields(cand_el.entry)
      |> Enum.split_with(&location_field?/1)

    cond do
      semantic == [] and location == [] ->
        nil

      semantic == [] ->
        cand_el
        |> base_delta(:location_only, [])
        |> Map.merge(%{changes: location, location_changes: []})

      true ->
        reasons = changed_reasons(cand_el.group, base_el.entry, cand_el.entry, new_categories)

        cand_el
        |> base_delta(:changed, reasons)
        |> Map.merge(%{changes: semantic, location_changes: location})
    end
  end

  defp base_delta(element, change, reasons) do
    %{
      id: element.id,
      group: element.group,
      kind: element.kind,
      change: change,
      severity: severity_of(reasons),
      reasons: reasons,
      source: Map.get(element.entry, "source"),
      changes: [],
      location_changes: [],
      element: nil
    }
  end

  defp severity_of([]), do: :info
  defp severity_of(_reasons), do: :warn

  # --- severity rules -----------------------------------------------------

  # (1) new external egress: a new http_boundary edge or a new external system.
  defp added_reasons(%{group: "edges", kind: "http_boundary"}, _new), do: [:new_external_egress]
  defp added_reasons(%{group: "external_systems"}, _new), do: [:new_external_egress]

  # A brand-new resource: personal data widens the surface.
  defp added_reasons(%{group: "resources", entry: entry}, new_categories) do
    category = data_category(entry)

    []
    # (3) a data_category value new to the whole system.
    |> prepend_if(category && MapSet.member?(new_categories, category), :new_data_category_value)
    # (4) new personal-data resource without enforced retention.
    |> prepend_if(
      personal?(entry) and retention_enforcement(entry) != "enforced",
      :unenforced_new_personal_data
    )
  end

  defp added_reasons(_element, _new), do: []

  defp changed_reasons("resources", before_entry, after_entry, new_categories) do
    before_cat = data_category(before_entry)
    after_cat = data_category(after_entry)

    []
    # (2) gaining a personal data_category (incl. no_personal_data -> category).
    |> prepend_if(is_nil(before_cat) and not is_nil(after_cat), :new_personal_data_category)
    # (3) a data_category value new to the whole system.
    |> prepend_if(
      after_cat && MapSet.member?(new_categories, after_cat),
      :new_data_category_value
    )
    # (4) retention-enforcement regression: enforced -> declared_not_enforced.
    |> prepend_if(
      retention_enforcement(before_entry) == "enforced" and
        retention_enforcement(after_entry) == "declared_not_enforced",
      :retention_enforcement_regression
    )
  end

  defp changed_reasons(_group, _before, _after, _new), do: []

  defp prepend_if(list, true, reason), do: [reason | list]
  defp prepend_if(list, _falsey, _reason), do: list

  # --- element indexing ---------------------------------------------------

  defp index_elements(model) do
    for group <- @element_groups,
        entry <- Map.get(model, group, []),
        is_map(entry),
        into: %{} do
      id = element_id(group, entry)
      {{group, id}, %{group: group, id: id, kind: kind_of(group, entry), entry: entry}}
    end
  end

  defp element_id(group, entry) do
    case Map.get(entry, "id") do
      nil -> group <> ":" <> fallback_key(entry)
      id -> to_string(id)
    end
  end

  defp fallback_key(entry) do
    entry["label"] || entry["name"] || Integer.to_string(:erlang.phash2(entry))
  end

  defp kind_of("resources", _entry), do: "resource"
  defp kind_of("edges", entry), do: Map.get(entry, "kind", "edge")
  defp kind_of("oban_workers", _entry), do: "oban_worker"
  defp kind_of("external_systems", _entry), do: "external_system"
  defp kind_of("runtime_components", _entry), do: "runtime_component"
  defp kind_of("entry_points", _entry), do: "entry_point"
  defp kind_of("declared_architecture", _entry), do: "declared_architecture"

  # --- privacy accessors --------------------------------------------------

  defp privacy(entry), do: Map.get(entry, "privacy", %{})
  defp posture(entry), do: entry |> privacy() |> Map.get("posture")
  defp data_category(entry), do: entry |> privacy() |> Map.get("data_category")

  defp retention_enforcement(entry),
    do: entry |> privacy() |> Map.get("retention", %{}) |> Map.get("enforcement")

  defp personal?(entry), do: posture(entry) == "declared" and not is_nil(data_category(entry))

  defp category_set(model) do
    model
    |> Map.get("resources", [])
    |> Enum.map(&data_category/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # --- field-level diff ---------------------------------------------------

  defp location_field?(%{field: "call_sites"}), do: true
  defp location_field?(%{field: "call_sites." <> _}), do: true
  defp location_field?(_delta), do: false

  defp diff_fields(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      field_diff(to_string(key), Map.get(left, key), Map.get(right, key))
    end)
  end

  defp field_diff(_key, same, same), do: []

  defp field_diff(key, left, right)
       when is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right) do
    left
    |> diff_fields(right)
    |> Enum.map(fn delta -> %{delta | field: key <> "." <> delta.field} end)
  end

  defp field_diff(key, left, right), do: [%{field: key, before: left, after: right}]

  # --- normalisation ------------------------------------------------------

  defp ensure_schema_match!(baseline, candidate) do
    base = Map.get(baseline, "schema_version")
    cand = Map.get(candidate, "schema_version")

    if base != cand do
      raise SchemaMismatchError, baseline_version: base, candidate_version: cand
    end

    :ok
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {canon_key(key), canonicalize(value)} end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  defp canonicalize(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: atom_to_string(atom)

  defp canonicalize(other), do: other

  defp canon_key(key) when is_atom(key), do: atom_to_string(key)
  defp canon_key(key), do: to_string(key)

  defp atom_to_string(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp sort_deltas(deltas), do: Enum.sort_by(deltas, & &1.id)
end
