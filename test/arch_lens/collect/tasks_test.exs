defmodule ArchLens.Collect.TasksTest do
  # async: false — loads modules and resolves scopes; keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Tasks
  alias ArchLens.Generator.{Attribution, Document, Model, Scope}
  alias Mix.Tasks.ArchLensFixture.{NoShortdoc, WithShortdoc}

  # A plain (non-Mix.Task) module, to prove the discovery filter drops non-tasks.
  alias ArchLens.CollectFixtures.Custom

  @modules [WithShortdoc, NoShortdoc, Custom]

  defp by_id(elements), do: Map.new(elements, &{&1.id, &1})

  describe "from_modules/1 — folding Mix task modules into :task entry points" do
    test "keeps only Mix.Task modules, dropping plain modules" do
      ids = @modules |> Tasks.from_modules() |> Enum.map(& &1.id)

      assert ids == ["task:arch_lens_fixture.no_shortdoc", "task:arch_lens_fixture.with_shortdoc"]
    end

    test "every element is a :task, source: collected, with a stable task:<name> id" do
      for element <- Tasks.from_modules(@modules) do
        assert element.kind == :task
        assert element.source == :collected
        assert String.starts_with?(element.id, "task:")
      end
    end

    test "the command is `mix <name>`, derived the way Mix derives a task name" do
      element =
        @modules
        |> Tasks.from_modules()
        |> by_id()
        |> Map.fetch!("task:arch_lens_fixture.with_shortdoc")

      assert element.command == "mix arch_lens_fixture.with_shortdoc"
    end

    test "the handler is the task module, so interface/namespace attribution can run" do
      element =
        @modules
        |> Tasks.from_modules()
        |> by_id()
        |> Map.fetch!("task:arch_lens_fixture.with_shortdoc")

      assert element.handler == "Mix.Tasks.ArchLensFixture.WithShortdoc"
      assert element.basis == "Mix.Task module Mix.Tasks.ArchLensFixture.WithShortdoc"
    end

    test "@shortdoc is carried verbatim as the description" do
      element =
        @modules
        |> Tasks.from_modules()
        |> by_id()
        |> Map.fetch!("task:arch_lens_fixture.with_shortdoc")

      assert element.description == "Fixture task that declares a shortdoc"
    end

    test "a task with no @shortdoc carries no description key (honest nil, nothing invented)" do
      element =
        @modules
        |> Tasks.from_modules()
        |> by_id()
        |> Map.fetch!("task:arch_lens_fixture.no_shortdoc")

      refute Map.has_key?(element, :description)
    end

    test "elements are de-duplicated by id and sorted" do
      elements = Tasks.from_modules([WithShortdoc, WithShortdoc, NoShortdoc])

      assert Enum.map(elements, & &1.id) == [
               "task:arch_lens_fixture.no_shortdoc",
               "task:arch_lens_fixture.with_shortdoc"
             ]
    end
  end

  describe "collect/1 — the host-app seam" do
    test "an explicit :mix_task_modules list bypasses the scan" do
      elements = Tasks.collect(mix_task_modules: @modules)

      assert Enum.map(elements, & &1.id) ==
               ["task:arch_lens_fixture.no_shortdoc", "task:arch_lens_fixture.with_shortdoc"]
    end

    test "no :app and no :mix_task_modules yields an empty inventory" do
      assert Tasks.collect([]) == []
    end

    test "collect(app: app) reads the app's lib-only tasks" do
      # arch_lens's own tasks live under lib/mix/tasks/, so the lib-only scan finds
      # them; the test/support fixtures are excluded (see the scan test).
      ids = [app: :arch_lens] |> Tasks.collect() |> Enum.map(& &1.id)

      assert "task:arch_lens.gen.architecture" in ids
      refute "task:arch_lens_fixture.with_shortdoc" in ids
    end
  end

  describe "attribution via the existing interface mechanism (unchanged)" do
    defmodule Cli do
      @moduledoc false
      use ArchLens.Context,
        does: "command-line surface",
        name: :cli,
        interface: ["Mix.Tasks.ArchLensFixture"]
    end

    defp cli_ctx, do: %{name: :cli, module: Cli, origin: :context_module}

    test "a task handler under a declared interface prefix is attributed to that context" do
      [element] =
        Tasks.collect(mix_task_modules: [WithShortdoc])
        |> Attribution.attribute([cli_ctx()])

      assert element.context == "cli"
      assert element.context_basis == "declared by context cli"
    end

    test "a task handler with no matching context is left Unattributed (never guessed)" do
      [element] =
        Tasks.collect(mix_task_modules: [WithShortdoc])
        |> Attribution.attribute([])

      assert element.context == nil
    end
  end

  describe "Scope.resolve auto-folds :task entry points" do
    defp folded_scope(extra) do
      Scope.resolve([domains: [], scanned_resources: [], edges: [], oban_workers: []] ++ extra)
    end

    test "mix tasks fold into the entry-point inventory with no router or cron" do
      kinds =
        folded_scope(mix_task_modules: @modules).entry_points
        |> Enum.map(& &1.kind)
        |> Enum.uniq()

      assert kinds == [:task]
    end

    test "the JSON model carries the task entries and stays schema_version 3" do
      json = folded_scope(mix_task_modules: @modules) |> Model.to_json() |> Jason.decode!()

      assert json["schema_version"] == 3

      task =
        Enum.find(json["entry_points"], &(&1["id"] == "task:arch_lens_fixture.with_shortdoc"))

      assert task["kind"] == "task"
      assert task["command"] == "mix arch_lens_fixture.with_shortdoc"
      assert task["description"] == "Fixture task that declares a shortdoc"
      assert task["source"] == "collected"
    end

    test "Markdown renders a Task group, the mix command, and the verbatim shortdoc" do
      md = folded_scope(mix_task_modules: @modules) |> Model.to_map() |> Document.render()

      assert md =~ "### Task (2)"
      assert md =~ "- `mix arch_lens_fixture.with_shortdoc` →"
      assert md =~ "Fixture task that declares a shortdoc"
    end

    test "the folded task inventory is byte-identical across resolves" do
      opts = [mix_task_modules: @modules]
      assert Model.to_json(folded_scope(opts)) == Model.to_json(folded_scope(opts))
    end
  end
end
