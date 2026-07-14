defmodule ArchLens.Generator.Sections.EntryPoints do
  @moduledoc """
  Renders the *entry points* seam — the app's inbound surface: HTTP routes, Oban
  cron schedules, Phoenix channels, and Mix tasks (the CLI surface).

  The sibling `ArchLens.Collect.*` collectors populate `Scope.entry_points` (routes
  from a host Phoenix router, cron from the Oban crontab, channels from socket
  mounts, tasks from the app's `Mix.Tasks.*` modules); this module owns how those
  elements serialise to the JSON model (`to_json/1`) and render to Markdown
  (`render/1`). Both are deterministic: elements are sorted by `{kind, method, path}`
  and the Markdown groups them by kind (in a fixed order) with per-group counts, so
  an unchanged inbound surface reproduces byte-identical output.

  Provenance (`source: "collected"`) is stamped on each element by the collector,
  not here — so a hand-supplied entry (e.g. a bare `%{label: ...}`) passes through
  unchanged.
  """

  @behaviour ArchLens.Generator.Section

  alias ArchLens.Generator.Section

  @heading "## Entry points"

  @kind_order ~w(browser api webhook oauth mcp cron channel task other)
  @kind_titles %{
    "browser" => "Browser",
    "api" => "API",
    "webhook" => "Webhook",
    "oauth" => "OAuth",
    "mcp" => "MCP",
    "cron" => "Cron",
    "channel" => "Channel",
    "task" => "Task",
    "other" => "Other"
  }

  @impl true
  def heading, do: @heading

  @impl true
  def to_json(entries) do
    entries
    |> Enum.map(&Section.jsonable/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @impl true
  def render([]), do: []

  def render(entries) do
    groups = Enum.group_by(entries, &kind_of/1)

    body =
      @kind_order
      |> Enum.flat_map(fn kind ->
        case Map.get(groups, kind) do
          nil -> []
          group -> group_lines(kind, Enum.sort_by(group, &sort_key/1))
        end
      end)
      |> drop_trailing_blank()

    [@heading, "", summary_line(entries), "" | body]
  end

  defp group_lines(kind, group) do
    ["### #{title(kind)} (#{length(group)})", "" | Enum.map(group, &bullet/1)] ++ [""]
  end

  defp bullet(entry) do
    case lead(entry) do
      nil -> Section.bullet(entry)
      lead -> "- #{lead} → #{handler_label(entry)}#{attribution_suffix(entry)}"
    end
  end

  # The leading code-span of a bullet: a route's method+path, a cron entry's
  # verbatim schedule, a channel entry's topic pattern, or a task entry's `mix …`
  # command. `nil` for an entry with none of these (a hand-supplied passthrough),
  # which falls back to Section.bullet.
  defp lead(entry) do
    cond do
      entry["kind"] == "cron" and is_binary(entry["schedule"]) ->
        "`#{entry["schedule"]}`"

      entry["kind"] == "channel" and is_binary(entry["topic"]) ->
        "`#{entry["topic"]}`"

      entry["kind"] == "task" and is_binary(entry["command"]) ->
        "`#{entry["command"]}`"

      is_binary(entry["method"]) and is_binary(entry["path"]) ->
        "`#{entry["method"]} #{entry["path"]}`"

      true ->
        nil
    end
  end

  defp handler_label(entry) do
    handler = entry["handler"] || "—"

    base =
      case entry["action"] do
        action when is_binary(action) -> "#{handler}##{action}"
        _ -> handler
      end

    base <> queue_suffix(entry)
  end

  defp queue_suffix(entry) do
    case {entry["kind"], entry["queue"]} do
      {"cron", queue} when is_binary(queue) -> " [queue: #{queue}]"
      _ -> ""
    end
  end

  # The attributed context and a detail clause, italicised:
  # ` — _<context> · <detail>_`. Context is the attributed bounded context, or
  # "Unattributed" when null. The detail prefers a verbatim `description` (a task's
  # `@shortdoc`) when present, else the classification `basis`; an element carrying
  # neither shows just the context. Elements without a `description` (routes, cron,
  # channels) render exactly as before.
  defp attribution_suffix(entry) do
    parts = [context_label(entry) | detail_part(entry)]
    " — _#{Enum.join(parts, " · ")}_"
  end

  defp context_label(entry) do
    case entry["context"] do
      name when is_binary(name) -> name
      _ -> "Unattributed"
    end
  end

  defp detail_part(entry) do
    case entry["description"] do
      description when is_binary(description) and description != "" -> [description]
      _ -> basis_part(entry["basis"])
    end
  end

  defp basis_part(basis) when is_binary(basis), do: [basis]
  defp basis_part(_basis), do: []

  defp summary_line(entries) do
    kinds = entries |> Enum.map(&kind_of/1) |> Enum.uniq() |> length()

    "_#{length(entries)} #{plural(length(entries), "entry point")} across #{kinds} #{plural(kinds, "kind")}._"
  end

  defp plural(1, word), do: word
  defp plural(_n, "entry point"), do: "entry points"
  defp plural(_n, word), do: word <> "s"

  defp title(kind), do: Map.get(@kind_titles, kind, kind)

  defp kind_of(entry), do: entry["kind"] || "other"

  defp sort_key(entry),
    do:
      {kind_index(kind_of(entry)), entry["method"] || "", entry["path"] || "", entry["id"] || ""}

  defp kind_index(kind), do: Enum.find_index(@kind_order, &(&1 == kind)) || length(@kind_order)

  defp drop_trailing_blank(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end
end
