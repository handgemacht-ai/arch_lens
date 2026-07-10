# arch_lens

Architecture lens for Ash-based rigs: declare each resource's **privacy posture**
and build an **edge inventory** of the boundaries the system crosses (PubSub
topics, Oban inserts, HTTP boundaries), so an architecture graph can be generated
deterministically.

This library is the core scaffold. Facade macros (that register edges) and the
deterministic generator (that reads them) land in later slices.

## Privacy declarations

Add the `ArchLens.Privacy` extension to a resource and declare its privacy
posture:

```elixir
defmodule MyApp.Contact do
  use Ash.Resource,
    domain: MyApp.Domain,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category :contact
    retention "P30D"
    legal_basis :consent
  end
end
```

A resource that carries no personal data declares the marker **instead of** a
`privacy` block:

```elixir
defmodule MyApp.FeatureFlag do
  use Ash.Resource,
    domain: MyApp.Domain,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end
end
```

Read declarations back with `ArchLens.Privacy.Info`:

```elixir
ArchLens.Privacy.Info.declaration(MyApp.Contact)
#=> %ArchLens.Privacy.Declaration{data_category: :contact, retention: "P30D", legal_basis: :consent}

ArchLens.Privacy.Info.no_personal_data?(MyApp.FeatureFlag)
#=> true

ArchLens.Privacy.Info.posture(MyApp.Contact)
#=> %ArchLens.Privacy.Declaration{...}   # or :no_personal_data / :undeclared
```

## Edge registry

`ArchLens.Edge.Registry` is the `{builder, call_site}`-keyed registry that facade
macros register edges into and the generator enumerates:

```elixir
ArchLens.Edge.Registry.register(%ArchLens.Edge{
  kind: :topic,
  builder: MyApp.Topics,
  call_site: {MyApp.Contact, "lib/my_app/contact.ex", 42},
  target: "contacts:updated"
})

ArchLens.Edge.Registry.all()
#=> [%ArchLens.Edge{kind: :topic, ...}]
```

## Optional Oban

Oban is an **optional** dependency. Any Oban-touching code is gated behind
`ArchLens.Edge.Registry.oban_available?/0` (a `Code.ensure_loaded?/1` guard), so
`arch_lens` compiles and runs with Oban absent.

## Roadmap

`docs/roadmap.md` records deferred work — fideslang alignment and cross-town
stitching of privacy/edge inventories across rigs.
