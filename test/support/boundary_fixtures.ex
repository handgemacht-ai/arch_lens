defmodule ArchLens.BoundaryFixtures do
  @moduledoc """
  Fixtures for `ArchLens.Collect.Boundaries` and the boundaries section tests.

  Two real `use Boundary` modules exercise the hex-`boundary` ingestion:

    * `Engine` — a strict boundary that exports three internal modules
      (`Container`, `Enums`, `Secret`) so the sanctioned / grandfathered /
      unclassified split can be exercised against real exports.
    * `Toolbox` — a relaxed boundary that depends on `Engine` and turns its
      outbound check off, exercising the deps and disabled-check rendering.

  `PlainModule` is not a boundary, proving the discovery filter drops non-boundary
  modules. They live under `test/support` on purpose: because their compiled source
  is not under `lib/`, the lib-only scan
  (`ArchLens.Generator.Scan.app_modules/1`) must not surface them — the same
  "declared outside `lib/` stays out of scope" guarantee the tasks scan asserts.
  The collector tests reach them directly via the `:boundary_modules` escape hatch.
  """
end

defmodule ArchLens.BoundaryFixtures.Engine.Container do
  @moduledoc false
end

defmodule ArchLens.BoundaryFixtures.Engine.Enums do
  @moduledoc false
end

defmodule ArchLens.BoundaryFixtures.Engine.Secret do
  @moduledoc false
end

defmodule ArchLens.BoundaryFixtures.Engine do
  @moduledoc false
  # `boundary` exports are declared relative to the boundary root: `Container`
  # here means `ArchLens.BoundaryFixtures.Engine.Container` (Module.concat), which
  # is the idiomatic way real apps declare them and what the collector reads back.
  use Boundary,
    type: :strict,
    deps: [],
    exports: [Container, Enums, Secret]
end

defmodule ArchLens.BoundaryFixtures.Toolbox do
  @moduledoc false
  use Boundary,
    type: :relaxed,
    check: [out: false],
    deps: [ArchLens.BoundaryFixtures.Engine],
    exports: []
end

defmodule ArchLens.BoundaryFixtures.PlainModule do
  @moduledoc false
  def noop, do: :ok
end
