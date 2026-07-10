defmodule Mix.Tasks.ArchLens.DiffTest do
  # async: false — the task invokes `Mix.raise` and writes to the Mix shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ArchLens.Diff, as: Task

  defp model(overrides) do
    Map.merge(
      %{
        "schema_version" => 1,
        "resources" => [],
        "edges" => [],
        "oban_workers" => [],
        "external_systems" => [],
        "runtime_components" => [],
        "entry_points" => [],
        "declared_architecture" => []
      },
      overrides
    )
  end

  defp res(module, category, enforcement) do
    %{
      "id" => "res:" <> module,
      "module" => module,
      "source" => "declared",
      "privacy" => %{
        "posture" => "declared",
        "data_category" => category,
        "retention" => %{"policy" => "P30D", "enforcement" => enforcement}
      }
    }
  end

  defp edge(kind, builder, target) do
    %{
      "id" => "edge:#{kind}:#{builder}=>#{target}",
      "kind" => kind,
      "source" => "collected",
      "builder" => builder,
      "target" => target,
      "call_sites" => [%{"file" => "lib/x.ex", "line" => 3}],
      "metadata" => %{}
    }
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "arch_lens_diff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    baseline = model(%{"resources" => [res("Keep", "session", "enforced")]})

    candidate =
      model(%{
        "resources" => [res("Keep", "session", "enforced")],
        "edges" => [edge("http_boundary", "C", "https://api.x.com")]
      })

    base_path = Path.join(dir, "baseline.json")
    cand_path = Path.join(dir, "candidate.json")
    File.write!(base_path, Jason.encode!(baseline))
    File.write!(cand_path, Jason.encode!(candidate))

    %{dir: dir, base_path: base_path, cand_path: cand_path}
  end

  test "report/1 diffs two fixture JSONs into JSON output", %{base_path: base, cand_path: cand} do
    assert {:ok, %{output: output, warn_count: 1, result: result}} =
             Task.report(base_file: base, candidate_file: cand, format: "json")

    decoded = Jason.decode!(output)
    assert decoded["summary"]["added"] == 1
    assert decoded["summary"]["warnings"] == 1
    assert [added] = decoded["added"]
    assert added["id"] == "edge:http_boundary:C=>https://api.x.com"
    assert added["severity"] == "warn"

    assert result.baseline_present == true
  end

  test "report/1 renders a markdown block with the CI marker", %{base_path: base, cand_path: cand} do
    assert {:ok, %{output: output}} =
             Task.report(base_file: base, candidate_file: cand, format: "markdown")

    assert String.starts_with?(output, "<!-- arch-lens-diff -->\n")
    assert output =~ "**WARN** new external data egress"
  end

  test "report/1 surfaces a schema_version mismatch as an error", %{dir: dir, cand_path: cand} do
    bad = Path.join(dir, "bad.json")
    File.write!(bad, Jason.encode!(model(%{"schema_version" => 99})))

    assert {:error, message} = Task.report(base_file: bad, candidate_file: cand, format: "json")
    assert message =~ "schema_version mismatch"
  end

  test "report/1 errors when the candidate file is missing", %{base_path: base, dir: dir} do
    assert {:error, message} =
             Task.report(
               base_file: base,
               candidate_file: Path.join(dir, "nope.json"),
               format: "json"
             )

    assert message =~ "candidate file not found"
  end

  test "report/1 rejects an unknown --format", %{base_path: base, cand_path: cand} do
    assert {:error, message} = Task.report(base_file: base, candidate_file: cand, format: "yaml")
    assert message =~ "unknown --format"
  end

  test "run/1 with --fail-on-warn exits non-zero when warnings exist", %{
    base_path: base,
    cand_path: cand
  } do
    assert_raise Mix.Error, ~r/--fail-on-warn/, fn ->
      capture_io(fn ->
        Task.run([
          "--base-file",
          base,
          "--candidate-file",
          cand,
          "--format",
          "text",
          "--fail-on-warn"
        ])
      end)
    end
  end

  test "run/1 without --fail-on-warn prints the report and does not raise", %{
    base_path: base,
    cand_path: cand
  } do
    output =
      capture_io(fn ->
        Task.run(["--base-file", base, "--candidate-file", cand, "--format", "text"])
      end)

    assert output =~ "1 added"
    assert output =~ "new external data egress"
  end
end
