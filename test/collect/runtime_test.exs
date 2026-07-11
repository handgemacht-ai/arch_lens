defmodule ArchLens.Collect.RuntimeTest do
  # async: false — a couple of cases start a real supervisor and read app env.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Runtime
  alias ArchLens.CollectFixtures.{Custom, Endpoint, PgRepo, TaskSup, Telemetry}

  @pg_repo_id "datastore:ArchLens.CollectFixtures.PgRepo"

  defp dns_cluster, do: Module.concat(["DNSCluster"])

  describe "datastores/1" do
    test "one element per ecto repo, technology introspected from the adapter" do
      assert [element] = Runtime.datastores(ecto_repos: [PgRepo])

      assert element == %{
               id: @pg_repo_id,
               label: "ArchLens.CollectFixtures.PgRepo",
               class: "repo",
               source: "collected",
               evidence: ["config:ecto_repos"],
               technology: "postgresql"
             }
    end

    test "omits technology when the adapter is not introspectable" do
      assert [element] = Runtime.datastores(ecto_repos: [Custom])
      refute Map.has_key?(element, :technology)
    end

    test "reads :ecto_repos from the otp_app config when not overridden" do
      Application.put_env(:arch_lens, :ecto_repos, [PgRepo])
      on_exit(fn -> Application.delete_env(:arch_lens, :ecto_repos) end)

      assert [%{id: @pg_repo_id}] = Runtime.datastores(otp_app: :arch_lens)
    end

    test "no otp_app and no override yields nothing" do
      assert Runtime.datastores([]) == []
    end
  end

  describe "job_runners/1 (Oban from config)" do
    test "an Oban runner is collected when Oban is configured" do
      assert [
               %{
                 id: "runner:Oban",
                 label: "Oban",
                 class: "oban",
                 source: "collected",
                 evidence: ["config:oban"]
               }
             ] = Runtime.job_runners(oban_config: [])
    end

    test "the configured Oban instance name is honored" do
      assert [%{id: "runner:ArchLens.CollectFixtures.Custom"}] =
               Runtime.job_runners(oban_config: [name: Custom])
    end

    test "no Oban runner when Oban is unconfigured" do
      assert Runtime.job_runners([]) == []
    end
  end

  describe "components/1 — supervision tree classification" do
    test "classifies well-known children and tags each source: collected" do
      children = [
        {PgRepo, self(), :supervisor, [PgRepo]},
        {Oban, self(), :supervisor, [Oban]},
        {Phoenix.PubSub, self(), :supervisor, [Phoenix.PubSub]},
        {Endpoint, self(), :supervisor, [Endpoint]},
        {Telemetry, self(), :worker, [Telemetry]},
        {dns_cluster(), self(), :worker, [dns_cluster()]},
        {TaskSup, self(), :supervisor, [Task.Supervisor]},
        {Custom, self(), :worker, [Custom]}
      ]

      by_class =
        [supervisor_children: children]
        |> Runtime.components()
        |> Map.new(&{&1.class, &1})

      assert by_class["repo"].id == @pg_repo_id
      assert by_class["repo"].technology == "postgresql"
      assert by_class["oban"].id == "runner:Oban"
      assert by_class["pubsub"].id == "component:Phoenix.PubSub"
      assert by_class["endpoint"].id == "component:ArchLens.CollectFixtures.Endpoint"
      assert by_class["telemetry"].id == "component:ArchLens.CollectFixtures.Telemetry"
      assert by_class["dns_cluster"].id == "component:DNSCluster"
      assert by_class["task_supervisor"].id == "runner:ArchLens.CollectFixtures.TaskSup"
      assert by_class["custom"].id == "component:ArchLens.CollectFixtures.Custom"

      elements = Map.values(by_class)
      assert Enum.all?(elements, &(&1.source == "collected"))
      assert Enum.all?(elements, &(&1.evidence == ["supervision_tree"]))
    end

    test "walks a real running supervisor" do
      {:ok, sup} =
        Supervisor.start_link(
          [{Task.Supervisor, name: :collect_runtime_test_tasks}],
          strategy: :one_for_one,
          name: :collect_runtime_test_root
        )

      on_exit(fn ->
        try do
          if Process.alive?(sup), do: Supervisor.stop(sup)
        catch
          :exit, _ -> :ok
        end
      end)

      # A named Task.Supervisor surfaces under its registered name as the child id.
      assert [%{class: "task_supervisor", id: "runner:collect_runtime_test_tasks"}] =
               Runtime.components(root_supervisor: :collect_runtime_test_root)
    end

    test "degrades to nothing when the named root supervisor is not running" do
      assert Runtime.components(root_supervisor: :arch_lens_no_such_supervisor) == []
    end

    test "degrades to nothing when no root supervisor is given" do
      assert Runtime.components([]) == []
    end
  end

  describe "module doc collection" do
    alias ArchLens.ModuleDocFixtures

    test "a module-backed component carries its moduledoc first paragraph" do
      children = [
        {ModuleDocFixtures.MultiParagraph, self(), :worker, [ModuleDocFixtures.MultiParagraph]}
      ]

      assert [element] = Runtime.components(supervisor_children: children)
      assert element.class == "custom"

      assert element.doc ==
               "Collects semantic review findings and writes them back to the annotation."
    end

    test "a datastore repo without a moduledoc omits the doc field" do
      assert [element] = Runtime.datastores(ecto_repos: [PgRepo])
      refute Map.has_key?(element, :doc)
    end

    test "a component whose subject is not a loaded module omits the doc field" do
      children = [{:some_registered_name, self(), :supervisor, [Task.Supervisor]}]
      assert [element] = Runtime.components(supervisor_children: children)
      refute Map.has_key?(element, :doc)
    end
  end

  describe "collect/1 — union, merge, degradation" do
    test "degrades to config-only collection with no live tree" do
      elements = Runtime.collect(ecto_repos: [PgRepo], oban_config: [])
      ids = Enum.map(elements, & &1.id)

      assert @pg_repo_id in ids
      assert "runner:Oban" in ids
      assert Enum.all?(elements, &("supervision_tree" not in &1.evidence))
    end

    test "merges config and live-tree evidence for the same element, without duplicating" do
      children = [
        {PgRepo, self(), :supervisor, [PgRepo]},
        {Oban, self(), :supervisor, [Oban]}
      ]

      elements =
        Runtime.collect(ecto_repos: [PgRepo], oban_config: [], supervisor_children: children)

      repo = Enum.find(elements, &(&1.class == "repo"))
      oban = Enum.find(elements, &(&1.class == "oban"))

      assert repo.evidence == ["config:ecto_repos", "supervision_tree"]
      assert repo.technology == "postgresql"
      assert oban.evidence == ["config:oban", "supervision_tree"]

      assert Enum.count(elements, &(&1.class == "repo")) == 1
      assert Enum.count(elements, &(&1.class == "oban")) == 1
    end

    test "the collected list is deterministically sorted by id" do
      children = [
        {Custom, self(), :worker, [Custom]},
        {PgRepo, self(), :supervisor, [PgRepo]}
      ]

      ids = Runtime.collect(supervisor_children: children) |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
    end
  end
end
