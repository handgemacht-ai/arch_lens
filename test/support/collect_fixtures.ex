defmodule ArchLens.CollectFixtures do
  @moduledoc """
  Fixtures for `ArchLens.Collect.EntryPoints`: a minimal real Phoenix router
  covering all five entry-point kinds (browser, api, webhook, oauth, mcp) and the
  dummy controllers/plug it routes to.

  Lives under `test/support` (rather than inline in a `_test.exs`) so both the
  collector tests and the mix-task tests can read the same router without ordering
  dependencies between test files.
  """
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
