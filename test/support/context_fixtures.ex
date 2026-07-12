# Realistically compiled fixtures for the in-place context annotation surface and
# the style/annotation gates. These are real modules compiled to disk under
# test/support, so `Code.fetch_docs/1` reads a genuine beam docs chunk for the
# `@moduledoc` fallback cases (a module defined inline in a `_test.exs` does not
# reliably carry one). Each fixture pins one case the gates and resolver must cover.

# --- resources the fixture domains own --------------------------------------

defmodule ArchLens.CtxFixtures.Accounts.User do
  @moduledoc false
  use Ash.Resource,
    domain: ArchLens.CtxFixtures.Accounts,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.CtxFixtures.Accounts.Workspace do
  @moduledoc false
  use Ash.Resource,
    domain: ArchLens.CtxFixtures.Accounts,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.CtxFixtures.Billing.Invoice do
  @moduledoc false
  use Ash.Resource,
    domain: ArchLens.CtxFixtures.Billing,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end

  attributes do
    uuid_primary_key(:id)
  end
end

# --- domains ----------------------------------------------------------------

defmodule ArchLens.CtxFixtures.Accounts do
  @moduledoc "This moduledoc must be ignored because the annotation supplies `does`."
  # Domain described by an explicit `does:` annotation (does_source: annotation).
  use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

  architecture do
    does("users, workspaces, and memberships")
  end

  resources do
    resource(ArchLens.CtxFixtures.Accounts.User)
    resource(ArchLens.CtxFixtures.Accounts.Workspace)
  end
end

defmodule ArchLens.CtxFixtures.Billing do
  @moduledoc "Subscriptions, invoices, and Stripe webhooks."
  # Domain that carries the extension but no `does:` — described via the moduledoc
  # fallback (does_source: moduledoc).
  use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

  resources do
    resource(ArchLens.CtxFixtures.Billing.Invoice)
  end
end

defmodule ArchLens.CtxFixtures.Telemetry do
  @moduledoc false
  # Domain explicitly excluded — passes the annotation gate, absent from the model.
  use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

  architecture do
    exclude(true)
  end

  resources do
  end
end

defmodule ArchLens.CtxFixtures.Undescribed do
  @moduledoc false
  # Domain with neither an annotation nor a moduledoc — the annotation-gate offender.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
  end
end

# --- plain root context modules ---------------------------------------------

defmodule ArchLens.CtxFixtures.Judge do
  @moduledoc "A moduledoc that the explicit annotation `does` overrides."
  use ArchLens.Context, does: "scores copy against the brand judges"
end

defmodule ArchLens.CtxFixtures.Judge.Scorer do
  @moduledoc false
  def score, do: :ok
end

defmodule ArchLens.CtxFixtures.Ingest do
  @moduledoc "Ingests raw events from the edge and normalises them."
  # A folder root with only a moduledoc — a context via the doc fallback.
end

defmodule ArchLens.CtxFixtures.Ingest.Parser do
  @moduledoc false
  def parse, do: :ok
end

defmodule ArchLens.CtxFixtures.Renamed do
  @moduledoc false
  use ArchLens.Context, name: :custom_name, does: "a context whose name is overridden"
end

defmodule ArchLens.CtxFixtures.Renamed.Worker do
  @moduledoc false
  def work, do: :ok
end

defmodule ArchLens.CtxFixtures.Excluded do
  @moduledoc false
  use ArchLens.Context, exclude: true
end

defmodule ArchLens.CtxFixtures.Excluded.Helper do
  @moduledoc false
  def help, do: :ok
end

# A folder (`Bare`) whose root module exists but carries neither an annotation nor a
# real @moduledoc — the annotation-gate offender among plain context modules.
defmodule ArchLens.CtxFixtures.Bare do
  @moduledoc false
end

defmodule ArchLens.CtxFixtures.Bare.Thing do
  @moduledoc false
  def thing, do: :ok
end

# --- flat single-file context modules (no directory of children) ------------

# A flat context whose `does` comes from an explicit annotation.
defmodule ArchLens.CtxFixtures.Blog do
  @moduledoc "A moduledoc the explicit annotation `does` overrides."
  use ArchLens.Context, does: "publishes posts and manages drafts"
end

# A flat context described only by its `@moduledoc` (annotated, does: omitted).
defmodule ArchLens.CtxFixtures.RateLimiter do
  @moduledoc "Throttles inbound requests per workspace."
  use ArchLens.Context
end

# A flat annotated context with a `name:` override.
defmodule ArchLens.CtxFixtures.OAuth2Server do
  @moduledoc false
  use ArchLens.Context, name: :oauth2_server, does: "issues OAuth 2.1 bearer tokens"
end

# A flat annotated context excluded from the model.
defmodule ArchLens.CtxFixtures.FlatExcluded do
  @moduledoc false
  use ArchLens.Context, exclude: true
end

# A flat UNannotated single-file module — must stay invisible and never be gated.
defmodule ArchLens.CtxFixtures.Loose do
  @moduledoc false
  def loose, do: :ok
end

# A folder (`Orphan`) with a child but NO root module — the style-gate offender.
defmodule ArchLens.CtxFixtures.Orphan.Thing do
  @moduledoc false
  def thing, do: :ok
end

# A folder (`Fixtures`) with a child but no root module — a style-gate offender
# unless the directory is listed in `ignore_namespaces`.
defmodule ArchLens.CtxFixtures.Fixtures.Helper do
  @moduledoc false
  def help, do: :ok
end

# A folder (`E2E`) whose mixed-case name `Macro.underscore`s to `e2_e`. The
# intuitive `:e2e` in `ignore_namespaces` must still excuse it from the style gate.
defmodule ArchLens.CtxFixtures.E2E.Spec do
  @moduledoc false
  def spec, do: :ok
end

defmodule ArchLens.CtxFixtures do
  @moduledoc """
  Helpers naming the fixture modules and module lists the gate/resolver tests drive
  through `ArchLens.Generator.Scope`.
  """

  @app_namespace ArchLens.CtxFixtures

  @doc "The namespace the fixtures live under (the fixture app's base module)."
  def app_namespace, do: @app_namespace

  @doc "The Ash domains a healthy fixture app declares (Accounts, Billing, Telemetry)."
  def domains,
    do: [
      ArchLens.CtxFixtures.Accounts,
      ArchLens.CtxFixtures.Billing,
      ArchLens.CtxFixtures.Telemetry
    ]

  @doc """
  A module list whose folders all have root modules — the happy path for the style
  gate (no `Orphan`/`Fixtures` offenders).
  """
  def healthy_modules do
    [
      ArchLens.CtxFixtures,
      ArchLens.CtxFixtures.Accounts,
      ArchLens.CtxFixtures.Accounts.User,
      ArchLens.CtxFixtures.Accounts.Workspace,
      ArchLens.CtxFixtures.Billing,
      ArchLens.CtxFixtures.Billing.Invoice,
      ArchLens.CtxFixtures.Telemetry,
      ArchLens.CtxFixtures.Judge,
      ArchLens.CtxFixtures.Judge.Scorer,
      ArchLens.CtxFixtures.Ingest,
      ArchLens.CtxFixtures.Ingest.Parser,
      ArchLens.CtxFixtures.Renamed,
      ArchLens.CtxFixtures.Renamed.Worker,
      ArchLens.CtxFixtures.Excluded,
      ArchLens.CtxFixtures.Excluded.Helper
    ]
  end
end
