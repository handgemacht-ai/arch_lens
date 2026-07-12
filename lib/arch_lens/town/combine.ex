defmodule ArchLens.Town do
  @moduledoc """
  The pure, JSON-in / JSON-out cross-app combiner.

  `combine/1` folds the already-committed per-app `architecture.gen.json` models of
  every town member into one deterministic `town_map` intermediate — the same
  discipline as `ArchLens.Generator.Model.to_map/1`, but one level up. It compiles
  nothing, starts nothing, and opens no database: it reads only fields already
  present in the committed artifacts, so re-running it against unchanged inputs is
  byte-identical.

  ## What it derives

    * **apps** — every input's declared identity plus its per-section counts, sorted
      by id.
    * **links** — an honest cross-app edge is emitted iff one app's external names an
      address (URI scheme or host) that another app declares as an alias. Direction
      is caller → target; provenance and any `does` prose are carried verbatim; an
      exact-path hit against the target app's `entry_points` attaches a
      `to_endpoint`. Nothing is fuzzy-matched and no prose is synthesised.
    * **unresolved_externals** — every external that matched no app alias is surfaced
      (per app, id-sorted), so nothing is silently dropped: an external either links
      to a town peer or stays visible on this list.

  ## Gates

    * **schema version** — every input must carry the per-app artifact schema
      (`ArchLens.Generator.Model.schema_version/0`); a mismatch raises
      `ArchLens.Town.SchemaMismatchError`, naming the file and its version.
    * **duplicate identity** — two inputs declaring the same `app.id` return
      `{:error, {:duplicate_identity, id, [path, path]}}`; town ids are unique by
      contract.

  The combined artifact carries its OWN independent `schema_version: 1` and
  `kind: "town_map"` — a distinct schema from the per-app artifact.
  """

  alias ArchLens.Generator.Model

  @town_schema_version 1

  # Transport hints an external's `via` can carry; HTTP client libraries all map to
  # the `http` transport, subprocess stays subprocess, anything else passes through
  # verbatim rather than being guessed at.
  @http_transports ~w(req tesla finch mint hackney httpoison gun)

  @type input :: %{required(:path) => String.t(), required(:model) => map()}

  @doc "The town artifact's own schema version (independent of the per-app schema)."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @town_schema_version

  @doc """
  Combine the per-app artifact `inputs` into the deterministic `town_map`
  intermediate.

  Each input is `%{path: committed_artifact_path, model: decoded_json_map}`.
  Raises `ArchLens.Town.SchemaMismatchError` when an input is not the expected
  per-app schema; returns `{:error, {:duplicate_identity, id, paths}}` when two
  inputs share an `app.id`; otherwise `{:ok, town_map}`.
  """
  @spec combine([input()]) ::
          {:ok, map()} | {:error, {:duplicate_identity, String.t(), [String.t()]}}
  def combine(inputs) when is_list(inputs) do
    :ok = assert_schema_versions(inputs)

    apps = Enum.map(inputs, &app_of/1)

    case duplicate_identity(apps) do
      nil -> {:ok, build_map(apps)}
      {id, paths} -> {:error, {:duplicate_identity, id, paths}}
    end
  end

  # --- gates -------------------------------------------------------------------

  defp assert_schema_versions(inputs) do
    expected = Model.schema_version()

    Enum.each(inputs, fn %{path: path, model: model} ->
      case model["schema_version"] do
        ^expected ->
          :ok

        other ->
          raise ArchLens.Town.SchemaMismatchError, path: path, version: other, expected: expected
      end
    end)
  end

  defp duplicate_identity(apps) do
    apps
    |> Enum.group_by(& &1.id, & &1.path)
    |> Enum.filter(fn {_id, paths} -> length(paths) > 1 end)
    |> Enum.sort_by(fn {id, _paths} -> id end)
    |> case do
      [{id, paths} | _] -> {id, Enum.sort(paths)}
      [] -> nil
    end
  end

  # --- app normalisation -------------------------------------------------------

  # Fold one input into the internal app record the rest of the pipeline reads: its
  # declared identity + alias index, the raw model (for count/endpoint lookups), and
  # its externals.
  defp app_of(%{path: path, model: model}) do
    app = model["app"] || %{}
    id = to_string(app["id"])
    aliases = list(app["aliases"])

    %{
      id: id,
      name: app["name"],
      aliases: aliases,
      alias_index: MapSet.new([id | aliases], &String.downcase/1),
      schema_version: model["schema_version"],
      externals: list(model["external_systems"]),
      entry_points: list(model["entry_points"]),
      declared_architecture: model["declared_architecture"],
      resources: list(model["resources"]),
      oban_workers: list(model["oban_workers"]),
      path: path
    }
  end

  # --- town map assembly -------------------------------------------------------

  defp build_map(apps) do
    links = links(apps)
    linked_external_ids = MapSet.new(links, &{&1.from, &1.from_external_id})

    %{
      schema_version: @town_schema_version,
      kind: "town_map",
      apps: apps |> Enum.map(&app_entry/1) |> Enum.sort_by(& &1.id),
      links: Enum.sort_by(links, & &1.id),
      unresolved_externals: unresolved(apps, linked_external_ids)
    }
  end

  defp app_entry(app) do
    %{
      id: app.id,
      aliases: app.aliases,
      source_schema_version: app.schema_version,
      counts: %{
        contexts: declared_count(app.declared_architecture, "contexts"),
        actors: declared_count(app.declared_architecture, "actors"),
        resources: length(app.resources),
        oban_workers: length(app.oban_workers),
        entry_points: length(app.entry_points),
        external_systems: length(app.externals)
      }
    }
    |> maybe_put(:name, app.name)
  end

  defp declared_count(declared, key) when is_map(declared), do: length(list(declared[key]))
  defp declared_count(_declared, _key), do: 0

  # --- links -------------------------------------------------------------------

  defp links(apps) do
    for caller <- apps,
        external <- caller.externals,
        target <- apps,
        target.id != caller.id,
        link = link(caller, external, target),
        link != nil do
      link
    end
  end

  # Emit a link iff one of the external's candidate address tokens is an alias of the
  # target app. The matching token is chosen deterministically (smallest token, then
  # source string), so re-runs are byte-stable, and its source string drives the
  # exact-path endpoint lookup.
  defp link(caller, external, target) do
    external
    |> candidate_tokens()
    |> Enum.filter(fn {token, _source} -> MapSet.member?(target.alias_index, token) end)
    |> Enum.sort()
    |> case do
      [] ->
        nil

      [{token, source} | _] ->
        external_id = to_string(external["id"])

        %{
          id: "link:#{caller.id}=>#{target.id}:#{external_id}",
          from: caller.id,
          to: target.id,
          kind: link_kind(external),
          basis: link_basis(external),
          provenance: list(external["provenance"]),
          from_external_id: external_id,
          matched_on: token
        }
        |> maybe_put(:does, present(external["does"]))
        |> maybe_put(:to_endpoint, endpoint(target, source))
    end
  end

  # Every address string an external carries — its declared `target`, its `vendor`,
  # and each `http_boundary` evidence value — parsed to its URI scheme and host. Each
  # token is paired with the source string it came from, so an alias match can strip
  # that string to a path for endpoint enrichment. Tokens are lower-cased (URIs are
  # case-insensitive in scheme and host); no substring or fuzzy matching is done.
  defp candidate_tokens(external) do
    external
    |> address_strings()
    |> Enum.flat_map(fn source ->
      uri = URI.parse(source)

      [uri.scheme, uri.host]
      |> Enum.filter(&present/1)
      |> Enum.map(fn token -> {String.downcase(token), source} end)
    end)
    |> Enum.uniq()
  end

  defp address_strings(external) do
    boundary_values = external |> http_boundary_evidence() |> Enum.map(& &1["value"])

    [external["target"], external["vendor"] | boundary_values]
    |> Enum.filter(&present/1)
  end

  defp http_boundary_evidence(external) do
    external["evidence"]
    |> list()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "http_boundary"))
  end

  # An external's transport, from its declared `via` (HTTP clients collapse to
  # `http`, subprocess stays subprocess, anything else passes through verbatim), else
  # `http` for a collected HTTP-boundary external, else the generic `external`.
  defp link_kind(external) do
    via = external["via"]

    cond do
      via in @http_transports -> "http"
      via == "subprocess" -> "subprocess"
      present(via) -> via
      http_boundary?(external) -> "http"
      true -> "external"
    end
  end

  defp link_basis(external) do
    if "declared" in list(external["provenance"]),
      do: "declared_external",
      else: "collected_boundary"
  end

  defp http_boundary?(external), do: http_boundary_evidence(external) != []

  # Best-effort, exact-path endpoint enrichment: strip the matched source string to
  # its path and look for an entry point in the target app declaring exactly that
  # path. On several matches (same path, different methods) the deterministically
  # first is taken; on none, `to_endpoint` is omitted. Never approximated.
  defp endpoint(target, source) do
    case URI.parse(source).path do
      path when is_binary(path) and path != "" ->
        target.entry_points
        |> Enum.filter(&(is_map(&1) and &1["path"] == path))
        |> Enum.sort_by(&{&1["method"], &1["handler"], &1["kind"]})
        |> List.first()
        |> endpoint_entry()

      _ ->
        nil
    end
  end

  defp endpoint_entry(nil), do: nil

  defp endpoint_entry(entry) do
    %{}
    |> maybe_put(:method, entry["method"])
    |> maybe_put(:path, entry["path"])
    |> maybe_put(:handler, entry["handler"])
    |> maybe_put(:kind, entry["kind"])
  end

  # --- unresolved externals ----------------------------------------------------

  defp unresolved(apps, linked_external_ids) do
    for app <- apps,
        external <- app.externals,
        external_id = to_string(external["id"]),
        not MapSet.member?(linked_external_ids, {app.id, external_id}) do
      %{app: app.id, external_id: external_id}
      |> maybe_put(:vendor, external["vendor"])
      |> maybe_put(:target, external["target"])
      |> maybe_put(:evidence, present_list(external["evidence"]))
    end
    |> Enum.sort_by(&{&1.app, &1.external_id})
  end

  # --- helpers -----------------------------------------------------------------

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp present_list([_ | _] = list), do: list
  defp present_list(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
