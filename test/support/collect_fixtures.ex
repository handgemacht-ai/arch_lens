defmodule ArchLens.CollectFixtures do
  @moduledoc """
  Plain (non-Ash) fixture modules for the `ArchLens.Collect.*` tests.

  Named so their module names drive the runtime-component classifier: `PgRepo`
  exposes `__adapter__/0` (an Ecto-repo shape), `Endpoint`/`Telemetry` match the
  name-based classes, and `TaskSup`/`Custom` stand in for a supervised task
  supervisor and an unclassified process. Kept out of the domain/Oban scans by
  being ordinary modules.
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
