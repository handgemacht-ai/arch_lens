defmodule ArchLens.Diff.ReportTest do
  use ExUnit.Case, async: true

  alias ArchLens.Diff

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

  defp res(module, privacy) do
    %{"id" => "res:" <> module, "module" => module, "source" => "declared", "privacy" => privacy}
  end

  defp declared(category, enforcement) do
    %{
      "posture" => "declared",
      "data_category" => category,
      "retention" => %{"policy" => "P30D", "enforcement" => enforcement}
    }
  end

  defp edge(kind, builder, target, lines) do
    %{
      "id" => "edge:#{kind}:#{builder}=>#{target}",
      "kind" => kind,
      "source" => "collected",
      "builder" => builder,
      "target" => target,
      "call_sites" => Enum.map(lines, &%{"file" => "lib/x.ex", "line" => &1}),
      "metadata" => %{}
    }
  end

  # A result with one WARN (new egress), one INFO added, one changed, one location-only.
  defp sample_result do
    baseline =
      model(%{
        "resources" => [res("Keep", declared("session", "enforced"))],
        "edges" => [edge("topic", "T", "old:topic", [3])]
      })

    candidate =
      model(%{
        "resources" => [
          res("Keep", declared("session", "enforced")),
          res("Extra", declared("session", "enforced"))
        ],
        "edges" => [
          edge("topic", "T", "old:topic", [9]),
          edge("http_boundary", "C", "https://api.x.com", [3])
        ]
      })

    Diff.compute(baseline, candidate)
  end

  describe "markdown" do
    test "opens with the stable marker, bolds WARN first, suppresses location_only" do
      md = Diff.render(sample_result(), :markdown)

      assert String.starts_with?(md, "<!-- arch-lens-diff -->\n")
      assert md =~ "### Architecture diff"
      assert md =~ "**2 added · 0 removed · 0 changed** · _1 location-only (suppressed)_"

      # WARN section appears, bolded, and before the INFO Changes section.
      assert md =~ "**Warnings**"

      assert md =~
               "**WARN** new external data egress — added `edge:http_boundary:C=>https://api.x.com` → https://api.x.com"

      warn_index = :binary.match(md, "**Warnings**") |> elem(0)
      changes_index = :binary.match(md, "**Changes**") |> elem(0)
      assert warn_index < changes_index

      # location_only edge id must not appear as a listed line.
      refute md =~ "moved `edge:topic:T=>old:topic`"
      # the info-added resource shows in Changes.
      assert md =~ "added `res:Extra`"
    end

    test "first adoption renders a graceful note" do
      candidate = model(%{"resources" => [res("A", declared("session", "enforced"))]})
      md = Diff.render(Diff.compute(nil, candidate), :markdown)

      assert md =~ "First architecture snapshot"
      assert md =~ "**1 added · 0 removed · 0 changed**"
    end
  end

  describe "json" do
    test "encodes a parseable, counted summary with stringified enums" do
      json = sample_result() |> Diff.render(:json) |> Jason.decode!()

      assert json["schema_version"] == 1
      assert json["baseline_present"] == true

      assert json["summary"] == %{
               "added" => 2,
               "removed" => 0,
               "changed" => 0,
               "location_only" => 1,
               "warnings" => 1
             }

      warn = Enum.find(json["added"], &(&1["severity"] == "warn"))
      assert warn["reasons"] == ["new_external_egress"]
      assert warn["change"] == "added"
      assert warn["element"]["target"] == "https://api.x.com"

      assert [loc] = json["location_only"]
      assert [%{"field" => "call_sites"}] = loc["changes"]
    end
  end

  describe "text" do
    test "renders headline counts and a WARN section" do
      text = Diff.render(sample_result(), :text)

      assert text =~ "2 added, 0 removed, 0 changed, 1 location-only"
      assert text =~ "WARN:"
      assert text =~ "new external data egress"
      assert text =~ "INFO:"
    end
  end
end
