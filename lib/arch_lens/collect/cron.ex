defmodule ArchLens.Collect.Cron do
  @moduledoc """
  Collects the `Oban.Plugins.Cron` crontab: the schedules that trigger each Oban
  worker.

  This collector serves two seams, both from the *same* verbatim crontab so they
  can never disagree:

    * `collect/1` — the `%{worker_module => [schedule]}` map the
      `ArchLens.Generator.Model.oban_worker_map/1` seam joins onto `oban_workers`
      (`scope.cron`), so a worker element carries the schedules that trigger it.
    * `entry_points/1` — one `:cron` entry-point element per crontab tuple, the
      Phoenix-independent inbound surface. A genuinely web-less app (no router,
      no channels) still has meaningful entry points: its scheduled jobs. Host-app
      wrappers concatenate these into `scope.entry_points`.

  Both read the loaded Oban config for `:app` (`Application.get_env(app, Oban)`),
  or an explicit `:oban_config` keyword list (mirroring `ArchLens.Collect.Runtime`)
  — the deterministic escape hatch for a durable crontab that only lives in a
  non-loaded env. The schedule string is stored verbatim (`"0 3 * * *"`, `"@daily"`)
  so nothing is invented. When Oban is not loaded and no explicit config is given,
  both return their empty value.
  """

  alias ArchLens.Edge

  @doc """
  A `%{worker_module => [schedule_string]}` map of the crontab schedules that
  trigger each Oban worker. Schedules are sorted and de-duplicated per worker.
  """
  @spec collect(keyword()) :: %{optional(module()) => [String.t()]}
  def collect(opts \\ []) do
    opts
    |> crontab()
    |> Enum.reduce(%{}, fn {schedule, worker, _queue}, acc ->
      Map.update(acc, worker, [schedule], &Enum.sort(Enum.uniq([schedule | &1])))
    end)
  end

  @doc """
  The `:cron` entry-point elements — one per crontab tuple — sorted by their stable
  `cron:<schedule>:<Worker>` id.

  Each element carries the verbatim `schedule`, the triggering worker as `handler`,
  the worker's `queue` (a crontab `queue:` override, else the worker's own
  `Oban.Worker` opts, else `"default"`), and `source: :collected`.
  """
  @spec entry_points(keyword()) :: [map()]
  def entry_points(opts \\ []) do
    opts
    |> crontab()
    |> Enum.map(&element/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp element({schedule, worker, queue}) do
    handler = Edge.module_name(worker)

    %{
      id: "cron:" <> schedule <> ":" <> handler,
      kind: :cron,
      source: :collected,
      schedule: schedule,
      queue: queue,
      handler: handler,
      basis: "Oban.Plugins.Cron crontab"
    }
  end

  # The flattened crontab as `{schedule, worker, queue}` tuples, from the loaded (or
  # explicitly supplied) Oban config. `[]` when Oban is absent and no config is given.
  defp crontab(opts) do
    case oban_config(opts) do
      nil -> []
      config -> config |> cron_inputs() |> Enum.flat_map(&normalize/1)
    end
  end

  defp oban_config(opts) do
    cond do
      Keyword.has_key?(opts, :oban_config) ->
        Keyword.get(opts, :oban_config)

      (app = Keyword.get(opts, :app)) && Code.ensure_loaded?(Oban) ->
        Application.get_env(app, Oban)

      true ->
        nil
    end
  end

  # The crontab lives under the `Oban.Plugins.Cron` plugin tuple; a top-level
  # `:crontab` key is also honoured for hand-supplied configs.
  defp cron_inputs(config) when is_list(config) do
    plugin_inputs =
      config
      |> Keyword.get(:plugins, [])
      |> Enum.flat_map(fn
        {Oban.Plugins.Cron, plugin_opts} when is_list(plugin_opts) ->
          Keyword.get(plugin_opts, :crontab, [])

        _ ->
          []
      end)

    plugin_inputs ++ Keyword.get(config, :crontab, [])
  end

  defp cron_inputs(_config), do: []

  defp normalize({schedule, worker}) when is_binary(schedule) and is_atom(worker) do
    [{schedule, worker, worker_queue(worker, [])}]
  end

  defp normalize({schedule, worker, entry_opts})
       when is_binary(schedule) and is_atom(worker) and is_list(entry_opts) do
    [{schedule, worker, worker_queue(worker, entry_opts)}]
  end

  defp normalize(_input), do: []

  defp worker_queue(worker, entry_opts) do
    cond do
      queue = Keyword.get(entry_opts, :queue) ->
        to_string(queue)

      function_exported?(worker, :__opts__, 0) ->
        worker.__opts__() |> Keyword.get(:queue, :default) |> to_string()

      true ->
        "default"
    end
  end
end
