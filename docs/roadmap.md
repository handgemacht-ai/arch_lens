# arch_lens roadmap

This document records what was **deliberately deferred**. Future goals read it to
know what is out of scope for the current work and what the intended next steps
are. Items here are NOT part of the current goal.

## Shipped in the core scaffold (this goal)

- `ArchLens.Privacy` Spark extension: a `privacy` block (`data_category`,
  `retention`, `legal_basis`) and a `no_personal_data` marker declared instead of
  a block.
- `ArchLens.Privacy.Info`: reads the declared posture back off a compiled
  resource.
- `ArchLens.Edge.Registry`: the `{builder, call_site}`-keyed edge registry that
  facade macros register into and the deterministic generator reads from.

## NEXT STEPS — deferred, not this goal's scope

### fideslang alignment

The privacy vocabulary is intentionally free-form for now: `data_category` and
`legal_basis` accept any atom and `retention` any string. The next step is to
align this vocabulary with [fideslang](https://ethyca.github.io/fideslang/), the
open privacy taxonomy:

- map `data_category` onto fideslang **data categories** (e.g.
  `user.contact.email`),
- map the resource's purpose onto fideslang **data uses**,
- map who the data is about onto fideslang **data subjects**,
- optionally validate declarations against a loaded fideslang taxonomy so
  `mix compile` rejects unknown categories.

Until then, the DSL stays permissive so teams can adopt the extension before the
taxonomy work lands.

### Cross-town stitching

Each rig produces its own privacy and edge inventory locally. The next step is to
**federate those inventories across multiple rigs** ("cross-town stitching"):

- export each rig's privacy declarations and registered edges as a portable
  artifact,
- stitch the per-rig edge graphs into one cross-town architecture graph so a
  topic published by one rig and consumed by another shows up as a single edge,
- reconcile privacy declarations for data that flows between rigs.

This requires a stable export format and a resolver that matches edges by
`builder`/`target` across rigs; both are out of scope here and depend on the
`al-gen` generator landing first.
