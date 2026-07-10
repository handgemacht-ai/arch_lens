defmodule ArchLens.CollectFixtures do
  @moduledoc """
  Shared fixtures for the `ArchLens.Collect.*` tests.

  Two families live here:

    * A minimal real Phoenix router (`Router`) covering all five entry-point kinds
      (browser, api, webhook, oauth, mcp) and the dummy controllers/plug it routes
      to, for `ArchLens.Collect.EntryPoints`.
    * Plain (non-Ash) modules whose names drive the runtime-component classifier:
      `PgRepo` exposes `__adapter__/0` (an Ecto-repo shape), `Endpoint`/`Telemetry`
      match the name-based classes, and `TaskSup`/`Custom` stand in for a
      supervised task supervisor and an unclassified process.

  Everything lives under `test/support` (rather than inline in a `_test.exs`) so
  the collector tests, the integration tests, and the mix-task tests can read the
  same fixtures without ordering dependencies between test files. The plain
  modules stay out of the domain/Oban scans by being ordinary modules.
  """

  defmodule PgRepo do
    @moduledoc false
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule Endpoint do
    @moduledoc false
  end

  defmodule Telemetry do
    @moduledoc false
  end

  defmodule TaskSup do
    @moduledoc false
  end

  defmodule Custom do
    @moduledoc false
  end
end

defmodule ArchLens.CollectFixtures.PageController do
  @moduledoc false
  def init(opts), do: opts
  def call(conn, _opts), do: conn
end

defmodule ArchLens.CollectFixtures.ApiController do
  @moduledoc false
  def init(opts), do: opts
  def call(conn, _opts), do: conn
end

defmodule ArchLens.CollectFixtures.WebhookController do
  @moduledoc false
  def init(opts), do: opts
  def call(conn, _opts), do: conn
end

defmodule ArchLens.CollectFixtures.OAuthController do
  @moduledoc false
  def init(opts), do: opts
  def call(conn, _opts), do: conn
end

defmodule ArchLens.CollectFixtures.MCPPlug do
  @moduledoc false
  def init(opts), do: opts
  def call(conn, _opts), do: conn
end

defmodule ArchLens.CollectFixtures.Router do
  @moduledoc false
  use Phoenix.Router

  def noop(conn, _opts), do: conn

  pipeline :browser do
    plug(:noop)
  end

  pipeline :api do
    plug(:noop)
  end

  pipeline :webhook do
    plug(:noop)
  end

  pipeline :oauth do
    plug(:noop)
  end

  scope "/", ArchLens.CollectFixtures do
    pipe_through(:browser)
    get("/dashboard", PageController, :index)
  end

  scope "/api", ArchLens.CollectFixtures do
    pipe_through(:api)
    get("/annotations", ApiController, :index)
    forward("/mcp", MCPPlug)
  end

  scope "/webhooks", ArchLens.CollectFixtures do
    pipe_through(:webhook)
    post("/stripe", WebhookController, :stripe)
  end

  scope "/oauth", ArchLens.CollectFixtures do
    pipe_through(:oauth)
    get("/authorize", OAuthController, :authorize)
  end
end
