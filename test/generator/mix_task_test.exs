defmodule Mix.Tasks.ArchLens.Gen.ArchitectureTest do
  # async: false — invokes the mix task, which reads the shared edge Registry.
  use ExUnit.Case, async: false

  alias ArchLens.Edge.Registry
  alias ArchLens.Generator.Architecture
  alias Mix.Tasks.ArchLens.Gen.Architecture, as: Task

  # A clean, fully-declared scope so `emit/3` can exercise the write/check glue
  # without the app scan (which, in test env, includes the undeclared fixture).
  @clean_opts [
    scanned_resources: [ArchLens.TestSupport.ValidPrivacyResource],
    edges: [],
    oban_workers: []
  ]

  setup do
    Registry.reset()
    dir = Path.join(System.tmp_dir!(), "arch_lens_task_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "architecture.gen.md")
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: path}
  end

  test "write mode renders the report to the artifact path", %{path: path} do
    assert Task.emit(@clean_opts, path, false) == :ok
    assert File.exists?(path)

    {:ok, expected} = Architecture.render(@clean_opts)
    assert File.read!(path) == expected
    assert File.read!(path) =~ "# Architecture"
  end

  test "--check passes when the committed artifact matches", %{path: path} do
    {:ok, md} = Architecture.render(@clean_opts)
    File.write!(path, md)

    assert Task.emit(@clean_opts, path, true) == :ok
  end

  test "--check fails and names the artifact on drift", %{path: path} do
    File.write!(path, "stale\n")

    assert_raise Mix.Error, ~r/#{Regex.escape(path)}/, fn ->
      Task.emit(@clean_opts, path, true)
    end
  end

  test "generation fails (non-zero) when the scanned app has an undeclared resource", %{
    path: path
  } do
    # Running against :arch_lens in test env scans the undeclared test-support
    # fixture, so the completeness gate aborts the task before writing anything.
    assert_raise Mix.Error, ~r/privacy declaration missing/, fn ->
      Task.run(["--output", path])
    end

    refute File.exists?(path)
  end
end
