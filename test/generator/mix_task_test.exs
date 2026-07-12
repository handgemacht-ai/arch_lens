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
    assert Jason.decode!(File.read!(json_path))["schema_version"] == 2
  end

  test "a :router option threads collected entry points into both artifacts", %{
    path: path,
    json_path: json_path
  } do
    opts = @clean_opts ++ [router: ArchLens.CollectFixtures.Router]
    assert Task.emit(opts, path, false) == :ok

    kinds =
      json_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("entry_points")
      |> Enum.map(& &1["kind"])
      |> Enum.uniq()
      |> Enum.sort()

    assert kinds == ["api", "browser", "mcp", "oauth", "webhook"]
    assert File.read!(path) =~ "## Entry points"
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

  test "generation fails (non-zero) and writes nothing when a scanned resource is undeclared",
       %{path: path, json_path: json_path} do
    # The completeness (privacy) gate aborts the task before writing anything.
    #
    # This previously drove the abort through `Task.run` scanning :arch_lens, which
    # only tripped because the undeclared test-support fixture leaked into the
    # MIX_ENV=test module list — exactly the environment-dependent leak this change
    # removes. Now that the app scan is lib-only, :arch_lens no longer surfaces that
    # fixture, so the abort path is exercised with an explicit undeclared resource:
    # deterministic and independent of the ambient MIX_ENV.
    opts = [
      scanned_resources: [ArchLens.TestSupport.UndeclaredResource],
      edges: [],
      oban_workers: []
    ]

    assert_raise Mix.Error, ~r/privacy declaration missing/, fn ->
      Task.emit(opts, path, false)
    end

    refute File.exists?(path)
    refute File.exists?(json_path)
  end
end
