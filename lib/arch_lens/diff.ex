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
    2. A resource crossing from `no_personal_data` (or undeclared) into personal
       `categories`, or otherwise gaining personal `categories`.
    3. A category value new to the whole system.
    4. A retention-enforcement regression (`enforced` → `declared_not_enforced`),
       or a newly-added personal-data resource without *enforced* retention.
    5. A classified resource downgraded to a reason-bearing `exempt` posture.
    6. An external system whose `verification` regresses `corroborated` → `manual`.

  A resource's `categories` are read from the v3 `categories` list, falling back to
  the deprecated singular `data_category` for not-yet-migrated declarations.

  ## Inputs

  Both maps are canonicalised on the way in (keys stringified, non-boolean atom
  values stringified), so a map straight from `Model.to_map/1` (atom keys, atom
  `categories`) and the same model round-tripped through JSON compare equal.

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
    context_dependencies
    flows
    decisions
    data_inventory
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
    []
    # (3) a category value new to the whole system.
    |> prepend_if(new_category?(categories(entry), new_categories), :new_data_category_value)
    # (4) new personal-data resource without enforced retention.
    |> prepend_if(
      personal?(entry) and retention_enforcement(entry) != "enforced",
      :unenforced_new_personal_data
    )
  end

  defp added_reasons(_element, _new), do: []

  defp changed_reasons("resources", before_entry, after_entry, new_categories) do
    before_cats = categories(before_entry)
    after_cats = categories(after_entry)

    []
    # (2) gaining personal categories (incl. no_personal_data -> categories).
    |> prepend_if(before_cats == [] and after_cats != [], :new_personal_data_category)
    # (3) a category value new to the whole system.
    |> prepend_if(new_category?(after_cats, new_categories), :new_data_category_value)
    # (4) retention-enforcement regression: enforced -> declared_not_enforced.
    |> prepend_if(
      retention_enforcement(before_entry) == "enforced" and
        retention_enforcement(after_entry) == "declared_not_enforced",
      :retention_enforcement_regression
    )
    # (5) a classified resource downgraded to a reason-bearing exemption.
    |> prepend_if(
      posture(before_entry) == "declared" and posture(after_entry) == "exempt",
      :privacy_classified_to_exempt
    )
  end

  # (6) external-evidence regression: a corroborated external drops to manual
  # (declared without code evidence).
  defp changed_reasons("external_systems", before_entry, after_entry, _new) do
    prepend_if(
      [],
      Map.get(before_entry, "verification") == "corroborated" and
        Map.get(after_entry, "verification") == "manual",
      :external_evidence_regression
    )
  end

  defp changed_reasons(_group, _before, _after, _new), do: []

  defp new_category?(categories, new_categories) do
    Enum.any?(categories, &MapSet.member?(new_categories, &1))
  end

  defp prepend_if(list, true, reason), do: [reason | list]
  defp prepend_if(list, _falsey, _reason), do: list

  # --- element indexing ---------------------------------------------------

  defp index_elements(model) do
    list_elements =
      for group <- @element_groups,
          entry <- Map.get(model, group, []),
          is_map(entry),
          into: %{} do
        id = element_id(group, entry)
        {{group, id}, %{group: group, id: id, kind: kind_of(group, entry), entry: entry}}
      end

    Map.merge(list_elements, declared_elements(Map.get(model, "declared_architecture")))
  end

  # `declared_architecture` is a map (`%{"actors", "contexts", "warnings"}`), not a
  # list, so it is indexed here rather than in the list loop above: actors and
  # contexts each become their own diffable element under a stable `decl:*` id.
  defp declared_elements(%{} = declared) do
    Map.merge(
      declared_group(declared, "actors", "decl:actor", "declared_actor"),
      declared_group(declared, "contexts", "decl:context", "declared_context")
    )
  end

  defp declared_elements(_declared), do: %{}

  defp declared_group(declared, key, id_prefix, kind) do
    for entry <- Map.get(declared, key, []),
        is_map(entry),
        into: %{} do
      id = id_prefix <> ":" <> declared_name(entry)

      {{"declared_architecture", id},
       %{group: "declared_architecture", id: id, kind: kind, entry: entry}}
    end
  end

  defp declared_name(entry) do
    to_string(entry["name"] || entry["label"] || :erlang.phash2(entry))
  end

  defp element_id(group, entry) do
    case Map.get(entry, "id") do
      nil -> group <> ":" <> fallback_key(entry)
      id -> to_string(id)
    end
  end

  defp fallback_key(entry) do
    entry["label"] || entry["name"] || entry["context"] ||
      Integer.to_string(:erlang.phash2(entry))
  end

  defp kind_of("resources", _entry), do: "resource"
  defp kind_of("edges", entry), do: Map.get(entry, "kind", "edge")
  defp kind_of("oban_workers", _entry), do: "oban_worker"
  defp kind_of("external_systems", _entry), do: "external_system"
  defp kind_of("runtime_components", _entry), do: "runtime_component"
  defp kind_of("entry_points", _entry), do: "entry_point"
  defp kind_of("context_dependencies", _entry), do: "context_dependency"
  defp kind_of("flows", _entry), do: "data_flow"
  defp kind_of("decisions", _entry), do: "decision"
  defp kind_of("data_inventory", _entry), do: "data_inventory"

  # --- privacy accessors --------------------------------------------------

  defp privacy(entry), do: Map.get(entry, "privacy", %{})
  defp posture(entry), do: entry |> privacy() |> Map.get("posture")

  # The resource's personal-data categories as a list. A v3 declaration carries a
  # `categories` list; a legacy declaration carries the deprecated singular
  # `data_category`, read here as a one-element list so both compare identically.
  defp categories(entry) do
    priv = privacy(entry)

    case Map.get(priv, "categories") do
      list when is_list(list) ->
        Enum.map(list, &to_string/1)

      _ ->
        case Map.get(priv, "data_category") do
          nil -> []
          category -> [to_string(category)]
        end
    end
  end

  defp retention_enforcement(entry),
    do: entry |> privacy() |> Map.get("retention", %{}) |> Map.get("enforcement")

  defp personal?(entry), do: posture(entry) == "declared" and categories(entry) != []

  defp category_set(model) do
    model
    |> Map.get("resources", [])
    |> Enum.flat_map(&categories/1)
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
