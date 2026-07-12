defmodule ArchLens.Collect.EntryPointsTest do
  # async: false — loads modules and resolves scopes; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.EntryPoints
  alias ArchLens.Generator.{Document, Model, Scope}

  defmodule CronMailer do
    @moduledoc false
    use Oban.Worker, queue: :mailers

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule ReportChannel do
    @moduledoc false
  end

  # A user socket that exposes the `__channels__/0` list the channel collector reads.
  defmodule ReportSocket do
    @moduledoc false
    def __channels__, do: [{"reports:*", ArchLens.Collect.EntryPointsTest.ReportChannel}]
  end

  # Deterministic collector seams via the escape hatches: an explicit Oban crontab
  # (no loaded app needed) and an explicit socket list (no Phoenix endpoint needed).
  @crontab [oban_config: [plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", CronMailer}]}]]]
  @socket_opts [sockets: [{"/socket", ReportSocket}]]

  defp by_kind(entries), do: Map.new(entries, &{&1.kind, &1})

  describe "collect/1 — real Phoenix router via Phoenix.Router.routes/1" do
    setup do
      %{entries: EntryPoints.collect(ArchLens.CollectFixtures.Router)}
    end

    test "classifies every one of the five kinds", %{entries: entries} do
      kinds = entries |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
      assert kinds == [:api, :browser, :mcp, :oauth, :webhook]
    end

    # Phoenix 1.8's Phoenix.Router.routes/1 no longer exposes pipe_through, so the
    # real router is classified on path segments (pipelines are empty here); the
    # pipeline-signal path is covered by the synthetic from_routes/1 tests below.
    test "each route records method, path, handler and a classification basis", %{
      entries: entries
    } do
      browser = by_kind(entries)[:browser]
      assert browser.method == "GET"
      assert browser.path == "/dashboard"
      assert browser.handler == "ArchLens.CollectFixtures.PageController"
      assert browser.action == "index"
      assert browser.pipelines == []
      assert browser.basis == "accepts html"
      assert browser.source == :collected
    end

    test "an /api path segment classifies the route as api", %{entries: entries} do
      api = by_kind(entries)[:api]
      assert api.method == "GET"
      assert api.path == "/api/annotations"
      assert api.basis == "path segment /api"
    end

    test "a /webhooks POST is a webhook, not an api call", %{entries: entries} do
      webhook = by_kind(entries)[:webhook]
      assert webhook.method == "POST"
      assert webhook.path == "/webhooks/stripe"
      assert webhook.basis == "path segment /webhooks"
    end

    test "an /oauth path segment classifies the route as oauth", %{entries: entries} do
      oauth = by_kind(entries)[:oauth]
      assert oauth.path == "/oauth/authorize"
      assert oauth.basis == "path segment /oauth"
    end

    test "a forwarded /api/mcp route is mcp (mcp segment beats the api segment)", %{
      entries: entries
    } do
      mcp = by_kind(entries)[:mcp]
      assert mcp.path =~ "/api/mcp"
      assert mcp.method == "*"
      assert mcp.basis == "path segment /mcp"
    end

    test "element ids are stable (method + path) and carry no file or line", %{entries: entries} do
      browser = by_kind(entries)[:browser]
      assert browser.id == "route:GET:/dashboard"
      refute Enum.any?(entries, &(&1.id =~ ".ex"))
      refute Enum.any?(entries, &Map.has_key?(&1, :line))
    end

    test "collecting twice is byte-identical, grouped in canonical kind order", %{
      entries: entries
    } do
      assert entries == EntryPoints.collect(ArchLens.CollectFixtures.Router)

      kinds_in_order = Enum.map(entries, & &1.kind)
      assert kinds_in_order == Enum.filter(EntryPoints.kinds(), &(&1 in kinds_in_order))
    end
  end

  describe "from_routes/1 — classification heuristics on synthetic routes" do
    defp route(fields), do: Enum.into(fields, %{kind: :match})

    test "a LiveView route (plug == Phoenix.LiveView.Plug) is a browser entry point" do
      [entry] =
        EntryPoints.from_routes([
          route(
            verb: :get,
            path: "/live",
            plug: Phoenix.LiveView.Plug,
            plug_opts: ArchLens.CollectFixtures.DashboardLive,
            pipe_through: [:browser]
          )
        ])

      assert entry.kind == :browser
      assert entry.basis == "LiveView route"
      assert entry.handler == "ArchLens.CollectFixtures.DashboardLive"
    end

    test "a LiveView route detected via metadata resolves its live module" do
      [entry] =
        EntryPoints.from_routes([
          route(
            verb: :get,
            path: "/live-meta",
            plug: Phoenix.LiveView.Plug,
            plug_opts: [],
            metadata: %{phoenix_live_view: {ArchLens.CollectFixtures.MetaLive, :index, %{}, %{}}},
            pipe_through: [:browser]
          )
        ])

      assert entry.kind == :browser
      assert entry.handler == "ArchLens.CollectFixtures.MetaLive"
    end

    test "a forward to an MCP/Hermes plug is mcp even when the path has no /mcp" do
      [entry] =
        EntryPoints.from_routes([
          route(
            verb: :*,
            path: "/gateway",
            plug: MyApp.HermesTransport,
            pipe_through: [:api],
            kind: :forward
          )
        ])

      assert entry.kind == :mcp
      assert entry.method == "*"
      assert entry.basis == "forwards to MCP plug MyApp.HermesTransport"
    end

    test "mcp path precedence beats an :api pipeline" do
      [entry] =
        EntryPoints.from_routes([
          route(verb: :post, path: "/api/mcp", plug: MyApp.MCPController, pipe_through: [:api])
        ])

      assert entry.kind == :mcp
    end

    test "an oauth path segment beats a browser pipeline" do
      [entry] =
        EntryPoints.from_routes([
          route(verb: :get, path: "/oauth/token", plug: MyApp.OAuth, pipe_through: [:browser])
        ])

      assert entry.kind == :oauth
      assert entry.basis == "path segment /oauth"
    end

    test "a pipeline signal wins over the path when both are present" do
      [entry] =
        EntryPoints.from_routes([
          route(verb: :get, path: "/api/things", plug: MyApp.Things, pipe_through: [:api])
        ])

      assert entry.kind == :api
      assert entry.basis == "pipeline :api"
    end

    test "an html-accepting controller route is a browser entry point" do
      [entry] =
        EntryPoints.from_routes([
          route(
            verb: :get,
            path: "/dash",
            plug: MyApp.Root,
            plug_opts: :home,
            pipe_through: [],
            accepts: ["html"]
          )
        ])

      assert entry.kind == :browser
      assert entry.basis == "accepts html"
    end

    test "a JSON controller behind a custom pipeline is an api entry point, not browser" do
      [entry] =
        EntryPoints.from_routes([
          route(
            verb: :post,
            path: "/internal/data",
            plug: MyApp.SecretController,
            plug_opts: :create,
            pipe_through: [:secure],
            metadata: %{accepts: ["json"]}
          )
        ])

      assert entry.kind == :api
      assert entry.basis == "accepts json"
    end

    test "a controller route with no determinable evidence is :other, never a silent :browser" do
      [entry] =
        EntryPoints.from_routes([
          route(verb: :get, path: "/thing", plug: MyApp.Thing, plug_opts: :show, pipe_through: [])
        ])

      assert entry.kind == :other
      assert entry.basis == "unclassified"
    end

    test "a forward to an unrecognised plug falls back to :other" do
      [entry] =
        EntryPoints.from_routes([
          route(verb: :*, path: "/proxy", plug: MyApp.SomeProxy, pipe_through: [], kind: :forward)
        ])

      assert entry.kind == :other
      assert entry.basis == "unclassified"
    end

    test "every collected element carries source: :collected" do
      entries =
        EntryPoints.from_routes([
          route(verb: :get, path: "/a", plug: MyApp.A, pipe_through: [:api]),
          route(verb: :get, path: "/b", plug: MyApp.B, pipe_through: [:browser])
        ])

      assert Enum.all?(entries, &(&1.source == :collected))
    end

    test "results are ordered by kind, then method, then path" do
      entries =
        EntryPoints.from_routes([
          route(verb: :post, path: "/api/z", plug: MyApp.Z, pipe_through: [:api]),
          route(verb: :get, path: "/dash", plug: MyApp.D, pipe_through: [:browser]),
          route(verb: :get, path: "/api/a", plug: MyApp.A, pipe_through: [:api])
        ])

      assert Enum.map(entries, & &1.path) == ["/dash", "/api/a", "/api/z"]
    end
  end

  describe "Scope + Model + Document integration" do
    defp scope do
      Scope.resolve(
        domains: [],
        scanned_resources: [ArchLens.TestSupport.ValidPrivacyResource],
        edges: [],
        oban_workers: [],
        router: ArchLens.CollectFixtures.Router
      )
    end

    test "Scope.resolve collects entry points from the :router option" do
      kinds = scope().entry_points |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
      assert kinds == [:api, :browser, :mcp, :oauth, :webhook]
    end

    test "an explicit :entry_points value wins over :router" do
      resolved =
        Scope.resolve(
          scanned_resources: [ArchLens.TestSupport.ValidPrivacyResource],
          edges: [],
          oban_workers: [],
          router: ArchLens.CollectFixtures.Router,
          entry_points: [%{label: "explicit"}]
        )

      assert resolved.entry_points == [%{label: "explicit"}]
    end

    test "the JSON model serialises entry points with source: collected and stable ids" do
      json = scope() |> Model.to_json() |> Jason.decode!()

      assert Enum.all?(json["entry_points"], &(&1["source"] == "collected"))
      assert "route:GET:/dashboard" in Enum.map(json["entry_points"], & &1["id"])
      refute Enum.any?(json["entry_points"], &(&1["id"] =~ ".ex"))
    end

    test "the Markdown groups entry points by kind with counts" do
      markdown = scope() |> Model.to_map() |> Document.render()

      assert markdown =~ "## Entry points"
      assert markdown =~ "### Browser (1)"
      assert markdown =~ "### API (1)"
      assert markdown =~ "### Webhook (1)"
      assert markdown =~ "### OAuth (1)"
      assert markdown =~ "### MCP (1)"
      assert markdown =~ "- `GET /dashboard` → ArchLens.CollectFixtures.PageController#index"
      assert markdown =~ "5 entry points across 5 kinds"
    end

    test "generating the model twice from the same router is byte-identical" do
      assert Model.to_json(scope()) == Model.to_json(scope())
    end
  end

  describe "Scope.resolve auto-folds cron and channel entry points" do
    defp folded_scope(extra) do
      Scope.resolve([domains: [], scanned_resources: [], edges: [], oban_workers: []] ++ extra)
    end

    test "a cron crontab contributes :cron entry points with no router" do
      [entry] = folded_scope(@crontab).entry_points

      assert entry.kind == :cron
      assert entry.id == "cron:0 3 * * *:ArchLens.Collect.EntryPointsTest.CronMailer"
      assert entry.queue == "mailers"
    end

    test "declared sockets contribute :channel entry points with no router" do
      [entry] = folded_scope(@socket_opts).entry_points

      assert entry.kind == :channel
      assert entry.topic == "reports:*"
      assert entry.handler == "ArchLens.Collect.EntryPointsTest.ReportChannel"
    end

    test "router, cron, and channel entries fold into one deduplicated inventory" do
      kinds =
        ([router: ArchLens.CollectFixtures.Router] ++ @crontab ++ @socket_opts)
        |> folded_scope()
        |> Map.fetch!(:entry_points)
        |> Enum.map(& &1.kind)
        |> Enum.uniq()
        |> Enum.sort()

      assert kinds == [:api, :browser, :channel, :cron, :mcp, :oauth, :webhook]
    end

    test "an app with no router, cron, or channels folds to an empty inventory" do
      assert folded_scope([]).entry_points == []
    end

    test "an explicit :entry_points value still wins over the folded seams" do
      resolved = folded_scope([entry_points: [%{label: "explicit"}]] ++ @crontab ++ @socket_opts)

      assert resolved.entry_points == [%{label: "explicit"}]
    end

    test "the folded inventory is deterministic across resolves" do
      opts = [router: ArchLens.CollectFixtures.Router] ++ @crontab ++ @socket_opts

      assert Model.to_json(folded_scope(opts)) == Model.to_json(folded_scope(opts))
    end

    test "Markdown renders the Cron and Channel groups from the folded seams" do
      md = (@crontab ++ @socket_opts) |> folded_scope() |> Model.to_map() |> Document.render()

      assert md =~ "### Cron (1)"
      assert md =~ "- `0 3 * * *` →"
      assert md =~ "[queue: mailers]"
      assert md =~ "### Channel (1)"
      assert md =~ "- `reports:*` →"
    end
  end
end
