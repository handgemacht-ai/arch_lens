defmodule ArchLens.Diff.Report do
  @moduledoc """
  Renders an `ArchLens.Diff.compute/2` result into one of three surfaces:

    * `:json` — the full result as pretty JSON (deltas id-sorted), for tooling.
    * `:text` — a plain-text summary for a terminal.
    * `:markdown` — a compact, PR-comment-ready block: headline counts, **WARN**
      lines first (bolded), then INFO lines, with `location_only` deltas suppressed
      (only counted). It opens with the stable HTML marker
      `<!-- arch-lens-diff -->` so CI can find and upsert the same comment.
  """

  alias ArchLens.Diff

  @marker "<!-- arch-lens-diff -->"

  @reason_text %{
    new_external_egress: "new external data egress",
    new_personal_data_category: "resource now holds personal data",
    new_data_category_value: "new data category for the whole system",
    retention_enforcement_regression: "retention no longer enforced",
    unenforced_new_personal_data: "new personal-data resource without enforced retention",
    privacy_classified_to_exempt: "classified resource downgraded to exempt",
    external_evidence_regression: "external no longer corroborated by code evidence"
  }

  @doc "The stable HTML marker CI greps for to upsert the same PR comment."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Render `result` in `format` (`:json`, `:text`, or `:markdown`)."
  @spec render(Diff.result(), :json | :text | :markdown) :: String.t()
  def render(result, :json), do: render_json(result)
  def render(result, :text), do: render_text(result)
  def render(result, :markdown), do: render_markdown(result)

  # --- json ---------------------------------------------------------------

  defp render_json(result) do
    %{
      "schema_version" => result.schema_version,
      "baseline_present" => result.baseline_present,
      "summary" => %{
        "added" => length(result.added),
        "removed" => length(result.removed),
        "changed" => length(result.changed),
        "location_only" => length(result.location_only),
        "warnings" => Diff.warning_count(result)
      },
      "added" => Enum.map(result.added, &delta_json/1),
      "removed" => Enum.map(result.removed, &delta_json/1),
      "changed" => Enum.map(result.changed, &delta_json/1),
      "location_only" => Enum.map(result.location_only, &delta_json/1)
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp delta_json(delta) do
    %{
      "id" => delta.id,
      "group" => delta.group,
      "kind" => delta.kind,
      "change" => to_string(delta.change),
      "severity" => to_string(delta.severity),
      "reasons" => Enum.map(delta.reasons, &to_string/1),
      "source" => delta.source
    }
    |> put_present("changes", Enum.map(delta.changes, &change_json/1))
    |> put_present("element", delta.element)
  end

  defp change_json(%{field: field, before: before, after: after_value}) do
    %{"field" => field, "before" => before, "after" => after_value}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # --- text ---------------------------------------------------------------

  defp render_text(result) do
    [
      "Architecture diff (schema #{inspect(result.schema_version)})",
      baseline_note(result, "  "),
      headline_text(result),
      "",
      warn_block_text(result),
      info_block_text(result)
    ]
    |> flatten_lines()
  end

  defp headline_text(result) do
    "  #{length(result.added)} added, #{length(result.removed)} removed, " <>
      "#{length(result.changed)} changed, #{length(result.location_only)} location-only"
  end

  defp warn_block_text(result) do
    case Diff.warnings(result) do
      [] -> []
      warnings -> ["WARN:" | Enum.map(warnings, &("  - " <> warn_line(&1)))] ++ [""]
    end
  end

  defp info_block_text(result) do
    case info_deltas(result) do
      [] -> ["INFO: (none)"]
      infos -> ["INFO:" | Enum.map(infos, &("  - " <> info_line(&1)))]
    end
  end

  # --- markdown -----------------------------------------------------------

  defp render_markdown(result) do
    [
      @marker,
      "### Architecture diff",
      "",
      baseline_note(result, "> "),
      headline_markdown(result),
      "",
      warn_block_markdown(result),
      info_block_markdown(result)
    ]
    |> flatten_lines()
  end

  defp headline_markdown(result) do
    counts =
      "**#{length(result.added)} added · #{length(result.removed)} removed · " <>
        "#{length(result.changed)} changed**"

    case length(result.location_only) do
      0 -> counts
      n -> counts <> " · _#{n} location-only (suppressed)_"
    end
  end

  defp warn_block_markdown(result) do
    case Diff.warnings(result) do
      [] -> []
      warnings -> ["**Warnings**", "" | Enum.map(warnings, &("- " <> warn_line_md(&1)))] ++ [""]
    end
  end

  defp info_block_markdown(result) do
    case info_deltas(result) do
      [] -> ["_No non-warning architectural changes._"]
      infos -> ["**Changes**", "" | Enum.map(infos, &("- " <> info_line(&1)))]
    end
  end

  # --- shared line rendering ----------------------------------------------

  defp info_deltas(result) do
    (result.added ++ result.removed ++ result.changed)
    |> Enum.filter(&(&1.severity == :info))
    |> Enum.sort_by(& &1.id)
  end

  defp warn_line(delta) do
    "#{reasons_text(delta)} — #{verb(delta.change)} `#{delta.id}`#{detail(delta)}"
  end

  defp warn_line_md(delta) do
    "**WARN** #{reasons_text(delta)} — #{verb(delta.change)} `#{delta.id}`#{detail(delta)}"
  end

  defp info_line(delta) do
    "#{verb(delta.change)} `#{delta.id}`#{detail(delta)}"
  end

  defp reasons_text(delta) do
    delta.reasons
    |> Enum.map(&Map.get(@reason_text, &1, to_string(&1)))
    |> Enum.join(", ")
  end

  defp verb(:added), do: "added"
  defp verb(:removed), do: "removed"
  defp verb(:changed), do: "changed"
  defp verb(:location_only), do: "moved"

  defp detail(%{change: :changed, changes: changes}), do: ": " <> changes_summary(changes)

  defp detail(%{change: change, element: element})
       when change in [:added, :removed] and is_map(element) do
    case element["target"] do
      target when is_binary(target) and target != "" -> " → #{target}"
      _ -> ""
    end
  end

  defp detail(_delta), do: ""

  defp changes_summary(changes) do
    changes
    |> Enum.map(fn %{field: field, before: before, after: after_value} ->
      "#{field} #{value(before)} → #{value(after_value)}"
    end)
    |> Enum.join("; ")
  end

  defp value(nil), do: "(none)"
  defp value(value) when is_binary(value), do: value
  defp value(value) when is_number(value), do: to_string(value)
  defp value(value), do: inspect(value)

  # --- helpers ------------------------------------------------------------

  defp baseline_note(%{baseline_present: true}, _prefix), do: []

  defp baseline_note(%{baseline_present: false}, prefix) do
    [prefix <> "First architecture snapshot — no baseline found; everything is new.", ""]
  end

  defp flatten_lines(lines) do
    lines
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
