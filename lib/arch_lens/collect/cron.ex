defmodule ArchLens.Collect.Cron do
  @moduledoc """
  Collects the `Oban.Plugins.Cron` crontab: the schedules that trigger each Oban
  worker.

  This is the wave-2 skeleton stub: `collect/1` returns an empty map, so the Oban
  worker enrichment seam (`ArchLens.Generator.Model.oban_worker_map/1`) folds in no
  cron schedules and the empty-v3 baseline renders. The wave-3 entry-points slice
  fleshes it to read the Oban config and return one entry per crontab tuple, both
  as `:cron` entry points and as the `worker => [schedules]` map the model joins
  onto `oban_workers`.
  """

  @doc """
  A `%{worker_module => [schedule_string]}` map of the crontab schedules that
  trigger each Oban worker.

  Skeleton stub — always `%{}`. Fleshed by the entry-points slice.
  """
  @spec collect(keyword()) :: %{optional(module()) => [String.t()]}
  def collect(_opts \\ []), do: %{}
end
