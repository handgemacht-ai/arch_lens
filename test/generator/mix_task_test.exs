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
    json_path = Architecture.json_artifact_for(path)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: path, json_path: json_path}
  end

  test "write mode renders both the Markdown report and its JSON sidecar", %{
    path: path,
    json_path: json_path
  } do
    assert Task.emit(@clean_opts, path, false) == :ok
    assert File.exists?(path)
    assert File.exists?(json_path)

    {:ok, %{markdown: markdown, json: json}} = Architecture.render_artifacts(@clean_opts)
    assert File.read!(path) == markdown
    assert File.read!(json_path) == json
    assert File.read!(path) =~ "# Architecture"
    assert Jason.decode!(File.read!(json_path))["schema_version"] == 1
  end

  test "--check passes when both committed artifacts match", %{path: path, json_path: json_path} do
    {:ok, %{markdown: markdown, json: json}} = Architecture.render_artifacts(@clean_opts)
    File.write!(path, markdown)
    File.write!(json_path, json)

    assert Task.emit(@clean_opts, path, true) == :ok
  end

  test "--check fails and names the Markdown artifact on drift", %{
    path: path,
    json_path: json_path
  } do
    {:ok, %{json: json}} = Architecture.render_artifacts(@clean_opts)
    File.write!(path, "stale\n")
    File.write!(json_path, json)

    assert_raise Mix.Error, ~r/#{Regex.escape(path)}/, fn ->
      Task.emit(@clean_opts, path, true)
    end
  end

  test "--check fails and names the JSON sidecar when only it drifts", %{
    path: path,
    json_path: json_path
  } do
    {:ok, %{markdown: markdown}} = Architecture.render_artifacts(@clean_opts)
    File.write!(path, markdown)
    File.write!(json_path, "{}\n")

    assert_raise Mix.Error, ~r/#{Regex.escape(json_path)}/, fn ->
      Task.emit(@clean_opts, path, true)
    end
  end

  test "generation fails (non-zero) when the scanned app has an undeclared resource", %{
    path: path,
    json_path: json_path
  } do
    # Running against :arch_lens in test env scans the undeclared test-support
    # fixture, so the completeness gate aborts the task before writing anything.
    assert_raise Mix.Error, ~r/privacy declaration missing/, fn ->
      Task.run(["--output", path])
    end

    refute File.exists?(path)
    refute File.exists?(json_path)
  end
end
