defmodule ArchLens.System do
  @moduledoc """
  Spark DSL for declaring an app's architecture on one app-level module.

      defmodule MyApp.Architecture do
        use ArchLens.System

        architecture do
          actor :developer, uses: [:api, :mcp, :browser], does: "captures annotations"
          external :stripe, via: :http, target: "https://api.stripe.com", does: "billing"
          context :accounts, does: "users and workspaces", modules: "MyApp.Accounts"
        end
      end

  The block declares three kinds of entity:

    * `actor name, uses: [...], does: "..."` — a human or system that drives the
      app through the listed entry points / surfaces,
    * `external name, via: :http | :subprocess | :otlp | :smtp, target: "...", does: "..."`
      — a third party the app talks to, and
    * `context name, does: "...", modules: "Prefix"` — a bounded context; `modules:`
      names the module prefix that houses a non-Ash-domain context.

  Read declarations back with `ArchLens.System.Info`. Unlike `ArchLens.Privacy`
  (an extension added to an `Ash.Resource`), this is a standalone DSL a module
  `use`s directly.

  The declarations are *validated against what the generator actually collected*
  at generation time (`ArchLens.System.Declared`): an actor may not claim an entry
  point that does not exist, a declared HTTP external must match a collected
  boundary or a dependency, and a context's module prefix must name real modules.
  """

  use Spark.Dsl, default_extensions: [extensions: [ArchLens.System.Dsl]]
end
