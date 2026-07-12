defmodule ArchLens.Collect.EntryPoints do
  @moduledoc """
  Collects a Phoenix router's routes into deterministic entry-point elements.

  `collect/1` is the host-app seam: given a Phoenix router module (passed by a
  host-app wrapper mix task), it reads every route via `Phoenix.Router.routes/1`
  and folds each into a stable-id element the generator can render. Phoenix is an
  optional dependency here — `collect/1` guards on `Code.ensure_loaded?/1` and
  calls `routes/1` through `apply/3`, so `arch_lens` compiles and runs with Phoenix
  absent (returning `[]`); the host app supplies Phoenix at runtime.

  `from_routes/1` is the pure core: it takes an already-fetched list of route
  structs (or plain maps with the same fields) and produces the sorted elements,
  so classification is testable without a running router.

  ## Stable identity

  A route element's id is `route:<METHOD>:<path>` — it never contains a file or
  line, matching the `kind:<canonical-name>` id rule for new element kinds. Every
  element carries `source: :collected` (these are scanned out of the router, not
  human-declared) and a `basis` string recording *why* it was classified the way
  it was, so a classification is auditable.

  ## Classification

  A *route* is classified into one of `#{inspect(~w(browser api webhook oauth mcp other)a)}`
  by a fixed-precedence heuristic (most specific first); the `:cron` and `:channel`
  kinds are contributed by the sibling `ArchLens.Collect.Cron` /
  `ArchLens.Collect.Channels` collectors, not by route classification, so
  `kinds/0` (the canonical render/sort order) lists them after `:mcp`:

    * `:mcp` — an `/mcp` path segment, or a forward targeting an MCP/Hermes plug.
    * `:oauth` — an `oauth` pipeline/path segment, or an OAuth-named plug.
    * `:webhook` — a `webhook(s)` pipeline/path segment, or a Webhook-named plug.
    * `:api` — an `api`/`bearer`/`token` pipeline, an `/api` path segment, an
      API-named plug (JSON + bearer-ish), or a route whose declared `accepts` are
      JSON-only.
    * `:browser` — a LiveView route, a `browser`/`html` pipeline, or a route whose
      declared `accepts` include `html`.
    * `:other` — matched none of the above, including a controller route with **no
      determinable evidence** (no pipeline, path, plug, or `accepts` signal). Such a
      route is `:other` with basis `"unclassified"` — never a silent `:browser`
      default, which would mislabel e.g. a JSON API sitting behind a custom auth
      pipeline whose plug/path carry no `api` token.

  Precedence is deliberate: a `/api/mcp` route is an MCP entry point, not a plain
  API one.

  Within each kind, signals are tried pipeline → path → plug-name, and the `basis`
  names the one that fired. `Phoenix.Router.routes/1` on Phoenix 1.8+ no longer
  exposes `pipe_through`, so pipeline signals only fire for callers that pass full
  route structs (older Phoenix, or hand-built maps); real 1.8 routers classify on
  the path, plug, and `accepts` signals. A route's accepted content types are read
  from a top-level `:accepts` field or `metadata[:accepts]` (Phoenix stores route
  `metadata`), when present. `pipelines` is still recorded (empty when the router
  does not expose them) so the element schema is stable.
  """

  alias ArchLens.Edge

  @kinds ~w(browser api webhook oauth mcp cron channel other)a

  @doc "The entry-point kinds, in the canonical render/sort order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Collects entry-point elements from a Phoenix `router` module.

  Returns `[]` when Phoenix is not loadable, so `arch_lens` stays Phoenix-free at
  compile time and a host without a router degrades cleanly.
  """
  @spec collect(module()) :: [map()]
  def collect(router) when is_atom(router) do
    if Code.ensure_loaded?(Phoenix.Router) and function_exported?(Phoenix.Router, :routes, 1) do
      Phoenix.Router
      |> apply(:routes, [router])
      |> from_routes()
    else
      []
    end
  end

  @doc """
  Folds already-fetched `routes` (structs or maps carrying `verb`, `path`, `plug`,
  `plug_opts`, `pipe_through`, `metadata`, `kind`) into sorted entry-point
  elements. Pure: `collect/1` is this applied to `Phoenix.Router.routes/1`.
  """
  @spec from_routes([map()]) :: [map()]
  def from_routes(routes) do
    routes
    |> Enum.map(&entry/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&sort_key/1)
  end

  defp entry(route) do
    route = normalize(route)
    {kind, basis} = classify(route)
    method = method_string(route.verb)
    live? = live_view?(route)

    %{
      id: "route:" <> method <> ":" <> route.path,
      kind: kind,
      source: :collected,
      method: method,
      path: route.path,
      handler: handler_name(route, live?),
      pipelines: route.pipe_through |> Enum.map(&to_string/1) |> Enum.sort(),
      basis: basis
    }
    |> maybe_put(:action, action_name(route, live?))
  end

  defp normalize(route) do
    metadata = Map.get(route, :metadata) || %{}

    %{
      verb: Map.get(route, :verb),
      path: Map.get(route, :path) || "",
      plug: Map.get(route, :plug),
      plug_opts: Map.get(route, :plug_opts),
      pipe_through: List.wrap(Map.get(route, :pipe_through)),
      metadata: metadata,
      accepts: normalize_accepts(Map.get(route, :accepts) || Map.get(metadata, :accepts)),
      forward?: Map.get(route, :kind) == :forward or Map.has_key?(metadata, :forward)
    }
  end

  defp normalize_accepts(nil), do: []

  defp normalize_accepts(value) do
    value
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- classification --------------------------------------------------------

  defp classify(route) do
    rules = [
      &mcp_rule/1,
      &oauth_rule/1,
      &webhook_rule/1,
      &api_rule/1,
      &browser_rule/1,
      &accepts_rule/1
    ]

    Enum.find_value(rules, {:other, "unclassified"}, & &1.(route))
  end

  defp mcp_rule(route) do
    cond do
      segment_matches?(route, ~r/^mcp/) ->
        {:mcp, "path segment /mcp"}

      route.forward? and module_matches?(route.plug, ~r/MCP|Hermes/i) ->
        {:mcp, "forwards to MCP plug " <> Edge.module_name(route.plug)}

      true ->
        nil
    end
  end

  defp oauth_rule(route), do: named_rule(route, :oauth, ~r/oauth/, ~r/^oauth/, ~r/oauth/i)

  defp webhook_rule(route),
    do: named_rule(route, :webhook, ~r/webhook/, ~r/^webhooks?$/, ~r/webhook/i)

  defp api_rule(route), do: named_rule(route, :api, ~r/api|bearer|token/, ~r/^api$/, ~r/api/i)

  # A kind identified by, in precedence order: a matching pipeline name, a matching
  # path segment, or a matching plug-module name. The basis names which fired.
  defp named_rule(route, kind, pipe_regex, segment_regex, plug_regex) do
    cond do
      name = pipeline_matching(route, pipe_regex) ->
        {kind, "pipeline :" <> name}

      segment = matching_segment(route, segment_regex) ->
        {kind, "path segment /" <> segment}

      module_matches?(route.plug, plug_regex) ->
        {kind, "plug " <> Edge.module_name(route.plug) <> " matches #{inspect(plug_regex)}"}

      true ->
        nil
    end
  end

  defp browser_rule(route) do
    cond do
      live_view?(route) -> {:browser, "LiveView route"}
      name = pipeline_matching(route, ~r/browser|html/) -> {:browser, "pipeline :" <> name}
      true -> nil
    end
  end

  # The last-resort evidence for a controller route that carried no pipeline, path,
  # or plug-name signal: the content types it declares it accepts. An html-accepting
  # route is a browser entry point; a JSON-only route is an API one. A route with no
  # `accepts` evidence is left to the `:other`/"unclassified" fallback rather than
  # being silently defaulted to `:browser`.
  defp accepts_rule(route) do
    cond do
      route.accepts == [] -> nil
      "html" in route.accepts -> {:browser, "accepts html"}
      json_only?(route.accepts) -> {:api, "accepts json"}
      true -> nil
    end
  end

  defp json_only?(accepts), do: accepts != [] and Enum.all?(accepts, &(&1 == "json"))

  # First pipeline (in sorted order, for determinism) whose name matches `regex`.
  defp pipeline_matching(route, regex) do
    route.pipe_through
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.find(&Regex.match?(regex, &1))
  end

  # First path segment (in path order) matching `regex`, ignoring params/globs.
  defp matching_segment(route, regex) do
    route.path
    |> String.split("/", trim: true)
    |> Enum.reject(&String.starts_with?(&1, [":", "*"]))
    |> Enum.find(&Regex.match?(regex, &1))
  end

  defp module_matches?(module, regex) when is_atom(module) and not is_nil(module) do
    Regex.match?(regex, Edge.module_name(module))
  end

  defp module_matches?(_module, _regex), do: false

  # --- handler / action ------------------------------------------------------

  defp live_view?(route) do
    route.plug == Phoenix.LiveView.Plug or
      (is_map(route.metadata) and Map.has_key?(route.metadata, :phoenix_live_view))
  end

  defp handler_name(route, true), do: route |> live_module() |> module_name()
  defp handler_name(route, false), do: module_name(route.plug)

  # A LiveView route's module lives in `metadata[:phoenix_live_view]` (real Phoenix
  # 1.8 stores `{LiveViewModule, action, …}` there while `plug_opts` is the *action*
  # atom, not the module). Reading metadata first is the fix: matching `plug_opts`
  # first mislabelled the handler as the action atom. Only when metadata carries no
  # module do we fall back to a module in `plug_opts` (older/synthetic routes), then
  # to the plug itself.
  defp live_module(route) do
    live_module_from_metadata(route) || plug_opts_module(route.plug_opts) || route.plug
  end

  defp live_module_from_metadata(route) do
    case Map.get(route.metadata, :phoenix_live_view) do
      tuple when is_tuple(tuple) and is_atom(elem(tuple, 0)) -> elem(tuple, 0)
      module when is_atom(module) and not is_nil(module) -> module
      _ -> nil
    end
  end

  defp plug_opts_module(module) when is_atom(module) and not is_nil(module), do: module

  defp plug_opts_module(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)),
    do: elem(tuple, 0)

  defp plug_opts_module(_plug_opts), do: nil

  defp action_name(route, false) do
    case route.plug_opts do
      action when is_atom(action) and not is_nil(action) -> Atom.to_string(action)
      _ -> nil
    end
  end

  # A LiveView route's action is the second element of the
  # `{LiveViewModule, action, …}` metadata tuple. A synthetic route whose
  # `plug_opts` holds the module (not an action) and carries no metadata tuple
  # yields no action.
  defp action_name(route, true) do
    case Map.get(route.metadata, :phoenix_live_view) do
      tuple when is_tuple(tuple) and tuple_size(tuple) >= 2 -> action_atom(elem(tuple, 1))
      _ -> nil
    end
  end

  defp action_atom(action) when is_atom(action) and not is_nil(action), do: Atom.to_string(action)
  defp action_atom(_action), do: nil

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: Edge.module_name(module)
  defp module_name(other), do: inspect(other)

  # --- misc ------------------------------------------------------------------

  defp segment_matches?(route, regex), do: matching_segment(route, regex) != nil

  defp method_string(nil), do: "*"
  defp method_string(:*), do: "*"
  defp method_string(verb) when is_atom(verb), do: verb |> Atom.to_string() |> String.upcase()
  defp method_string(verb) when is_binary(verb), do: String.upcase(verb)

  defp sort_key(%{kind: kind, method: method, path: path}) do
    {kind_index(kind), method, path}
  end

  defp kind_index(kind), do: Enum.find_index(@kinds, &(&1 == kind)) || length(@kinds)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
