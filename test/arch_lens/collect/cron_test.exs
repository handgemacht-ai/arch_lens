defmodule ArchLens.Collect.CronTest do
  # async: false — defines Oban.Worker modules and reads Application config.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Cron
  alias ArchLens.Generator.Sections.EntryPoints

  defmodule MailerWorker do
    @moduledoc false
    use Oban.Worker, queue: :mailers

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule DefaultWorker do
    @moduledoc false
    use Oban.Worker

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule PlainModule do
    @moduledoc false
  end

  defp config(crontab) do
    [oban_config: [plugins: [{Oban.Plugins.Cron, crontab: crontab}]]]
  end

  describe "collect/1 — the {worker => [schedule]} map for the oban_worker_map seam" do
    test "maps each worker to the verbatim schedules that trigger it" do
      map =
        config([
          {"0 3 * * *", MailerWorker},
          {"@daily", MailerWorker},
          {"*/5 * * * *", DefaultWorker}
        ])
        |> Cron.collect()

      assert map == %{
               MailerWorker => ["0 3 * * *", "@daily"],
               DefaultWorker => ["*/5 * * * *"]
             }
    end

    test "schedules per worker are de-duplicated and sorted" do
      map = Cron.collect(config([{"@daily", MailerWorker}, {"@daily", MailerWorker}]))
      assert map == %{MailerWorker => ["@daily"]}
    end

    test "an absent Oban config yields an empty map" do
      assert Cron.collect([]) == %{}
      assert Cron.collect(app: :arch_lens_no_such_app) == %{}
    end

    test "a top-level :crontab key is honoured alongside the plugin form" do
      map = Cron.collect(oban_config: [crontab: [{"0 0 * * *", MailerWorker}]])
      assert map == %{MailerWorker => ["0 0 * * *"]}
    end
  end

  describe "entry_points/1 — :cron entry-point elements" do
    test "one element per crontab tuple, sorted by stable id, with verbatim schedule" do
      [first, second] =
        config([{"@daily", MailerWorker}, {"0 3 * * *", MailerWorker}])
        |> Cron.entry_points()

      assert first.id == "cron:0 3 * * *:ArchLens.Collect.CronTest.MailerWorker"
      assert first.kind == :cron
      assert first.source == :collected
      assert first.schedule == "0 3 * * *"
      assert first.handler == "ArchLens.Collect.CronTest.MailerWorker"
      assert first.basis == "Oban.Plugins.Cron crontab"
      assert second.schedule == "@daily"
    end

    test "queue comes from the worker's Oban.Worker opts" do
      [element] = Cron.entry_points(config([{"0 3 * * *", MailerWorker}]))
      assert element.queue == "mailers"
    end

    test "a worker without a declared queue falls back to \"default\"" do
      [element] = Cron.entry_points(config([{"0 3 * * *", DefaultWorker}]))
      assert element.queue == "default"
    end

    test "a crontab-tuple :queue override wins over the worker's own queue" do
      [element] = Cron.entry_points(config([{"0 3 * * *", MailerWorker, queue: :urgent}]))
      assert element.queue == "urgent"
    end

    test "a non-Oban.Worker module still yields a cron entry with the default queue" do
      [element] = Cron.entry_points(config([{"0 3 * * *", PlainModule}]))
      assert element.handler == "ArchLens.Collect.CronTest.PlainModule"
      assert element.queue == "default"
    end

    test "an absent Oban config yields no entry points" do
      assert Cron.entry_points([]) == []
    end

    test "collecting twice from the same config is byte-identical" do
      cfg = config([{"0 3 * * *", MailerWorker}, {"@daily", DefaultWorker}])
      assert Cron.entry_points(cfg) == Cron.entry_points(cfg)
    end
  end

  describe "rendering :cron entries in the entry-points section" do
    test "a cron entry renders under a Cron group with its schedule, queue and handler" do
      markdown =
        config([{"0 3 * * *", MailerWorker}])
        |> Cron.entry_points()
        |> EntryPoints.to_json()
        |> EntryPoints.render()
        |> Enum.join("\n")

      assert markdown =~ "### Cron (1)"

      assert markdown =~
               "- `0 3 * * *` → ArchLens.Collect.CronTest.MailerWorker [queue: mailers] — _Unattributed · Oban.Plugins.Cron crontab_"
    end
  end
end
