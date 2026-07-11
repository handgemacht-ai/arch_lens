defmodule ArchLens.DiffTest do
  use ExUnit.Case, async: true

  alias ArchLens.Diff

  # --- fixture builders ---------------------------------------------------

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
    %{
      "id" => "res:" <> module,
      "module" => module,
      "source" => "declared",
      "discovered_via_scan" => false,
      "privacy" => privacy
    }
  end

  defp no_personal_data, do: %{"posture" => "no_personal_data"}

  defp declared(category, enforcement, legal_basis \\ "contract") do
    %{
      "posture" => "declared",
      "data_category" => category,
      "legal_basis" => legal_basis,
      "retention" => %{"policy" => "P30D", "enforcement" => enforcement}
    }
  end

  defp edge(kind, builder, target, lines, metadata \\ %{}) do
    %{
      "id" => "edge:#{kind}:#{builder}=>#{target}",
      "kind" => kind,
      "source" => "collected",
      "builder" => builder,
      "target" => target,
      "call_sites" => Enum.map(lines, &%{"file" => "lib/x.ex", "line" => &1}),
      "metadata" => metadata
    }
  end

  defp actor(name, does, uses) do
    %{"name" => name, "does" => does, "uses" => uses, "source" => "declared"}
  end

  defp declared_context(name, does, modules) do
    %{"name" => name, "does" => does, "modules" => modules, "source" => "declared"}
  end

  # The real structured declared_architecture shape produced by
  # ArchLens.System.Declared / DeclaredArchitecture.to_json: a MAP, not a list.
  defp declared_arch(actors, contexts) do
    %{"actors" => actors, "contexts" => contexts, "warnings" => []}
  end

  defp ids(deltas), do: Enum.map(deltas, & &1.id)

  defp find(deltas, id), do: Enum.find(deltas, &(&1.id == id))

  # --- structural diff ----------------------------------------------------

  describe "compute/2 keying by stable id" do
    test "partitions elements into added / removed / changed by stable id" do
      baseline =
        model(%{
          "resources" => [
            res("A", no_personal_data()),
            res("B", declared("session", "enforced"))
          ]
        })

      candidate =
        model(%{
          "resources" => [
            res("B", declared("session", "enforced", "consent")),
            res("C", no_personal_data())
          ]
        })

      result = Diff.compute(baseline, candidate)

      assert ids(result.added) == ["res:C"]
      assert ids(result.removed) == ["res:A"]
      assert ids(result.changed) == ["res:B"]
      assert result.baseline_present == true
      assert result.schema_version == 1

      changed = find(result.changed, "res:B")

      assert changed.changes == [
               %{field: "privacy.legal_basis", before: "contract", after: "consent"}
             ]
    end

    test "identical models produce empty diffs" do
      m = model(%{"resources" => [res("A", declared("session", "enforced"))]})
      result = Diff.compute(m, m)

      assert result.added == []
      assert result.removed == []
      assert result.changed == []
      assert result.location_only == []
    end
  end

  describe "location_only handling" do
    test "a call-site-only change is location_only, never in the headline counts" do
      baseline = model(%{"edges" => [edge("http_boundary", "Client", "https://api.x.com", [3])]})
      candidate = model(%{"edges" => [edge("http_boundary", "Client", "https://api.x.com", [7])]})

      result = Diff.compute(baseline, candidate)

      assert result.added == []
      assert result.removed == []
      assert result.changed == []
      assert [delta] = result.location_only
      assert delta.change == :location_only
      assert delta.severity == :info
      assert [%{field: "call_sites"}] = delta.changes
    end

    test "a mix of semantic and call-site change is a changed delta; location split off" do
      baseline = model(%{"edges" => [edge("oban_insert", "W", "W", [3], %{"a" => 1})]})
      candidate = model(%{"edges" => [edge("oban_insert", "W", "W", [7], %{"a" => 2})]})

      result = Diff.compute(baseline, candidate)

      assert result.location_only == []
      assert [changed] = result.changed
      assert changed.changes == [%{field: "metadata.a", before: 1, after: 2}]
      assert [%{field: "call_sites"}] = changed.location_changes
    end
  end

  # --- severity rules -----------------------------------------------------

  describe "severity rule (a): new external egress" do
    test "a new http_boundary edge warns" do
      baseline = model(%{})
      candidate = model(%{"edges" => [edge("http_boundary", "Client", "https://api.x.com", [3])]})

      assert [delta] = Diff.compute(baseline, candidate).added
      assert delta.severity == :warn
      assert delta.reasons == [:new_external_egress]
    end

    test "a new external system warns" do
      baseline = model(%{})
      candidate = model(%{"external_systems" => [%{"name" => "Stripe", "label" => "Stripe"}]})

      assert [delta] = Diff.compute(baseline, candidate).added
      assert delta.severity == :warn
      assert delta.reasons == [:new_external_egress]
    end

    test "a topic edge is not egress and stays info" do
      baseline = model(%{})
      candidate = model(%{"edges" => [edge("topic", "T", "user:updated", [3])]})

      assert [delta] = Diff.compute(baseline, candidate).added
      assert delta.severity == :info
    end
  end

  describe "severity rule (b): resource gains personal data" do
    test "no_personal_data -> a personal category warns" do
      baseline =
        model(%{
          "resources" => [
            res("X", no_personal_data()),
            res("Y", declared("session", "enforced"))
          ]
        })

      candidate =
        model(%{
          "resources" => [
            res("X", declared("session", "enforced")),
            res("Y", declared("session", "enforced"))
          ]
        })

      changed = find(Diff.compute(baseline, candidate).changed, "res:X")
      assert changed.severity == :warn
      assert :new_personal_data_category in changed.reasons
    end
  end

  describe "severity rule (c): data category new to the whole system" do
    test "changing to a system-new category warns" do
      baseline = model(%{"resources" => [res("X", declared("session", "enforced"))]})
      candidate = model(%{"resources" => [res("X", declared("biometric", "enforced"))]})

      changed = find(Diff.compute(baseline, candidate).changed, "res:X")
      assert changed.severity == :warn
      assert :new_data_category_value in changed.reasons
      refute :new_personal_data_category in changed.reasons
    end

    test "reusing an existing category does not trigger the system-new rule" do
      baseline =
        model(%{
          "resources" => [
            res("X", declared("session", "enforced")),
            res("Y", no_personal_data())
          ]
        })

      candidate =
        model(%{
          "resources" => [
            res("X", declared("session", "enforced")),
            res("Y", declared("session", "enforced"))
          ]
        })

      changed = find(Diff.compute(baseline, candidate).changed, "res:Y")
      refute :new_data_category_value in changed.reasons
    end
  end

  describe "severity rule (d): retention" do
    test "enforced -> declared_not_enforced is a regression warning" do
      baseline = model(%{"resources" => [res("X", declared("session", "enforced"))]})

      candidate =
        model(%{"resources" => [res("X", declared("session", "declared_not_enforced"))]})

      changed = find(Diff.compute(baseline, candidate).changed, "res:X")
      assert changed.severity == :warn
      assert :retention_enforcement_regression in changed.reasons
    end

    test "a new personal-data resource without enforced retention warns" do
      baseline = model(%{"resources" => [res("Q", declared("session", "enforced"))]})

      candidate =
        model(%{
          "resources" => [
            res("Q", declared("session", "enforced")),
            res("N", declared("session", "declared_not_enforced"))
          ]
        })

      added = find(Diff.compute(baseline, candidate).added, "res:N")
      assert added.severity == :warn
      assert :unenforced_new_personal_data in added.reasons
    end

    test "a new personal-data resource with enforced retention and a known category stays info" do
      baseline = model(%{"resources" => [res("Q", declared("session", "enforced"))]})

      candidate =
        model(%{
          "resources" => [
            res("Q", declared("session", "enforced")),
            res("M", declared("session", "enforced"))
          ]
        })

      added = find(Diff.compute(baseline, candidate).added, "res:M")
      assert added.severity == :info
      assert added.reasons == []
    end
  end

  # --- edge cases ---------------------------------------------------------

  describe "baseline absent (first adoption)" do
    test "nil baseline reports everything as added and flags baseline_present false" do
      candidate =
        model(%{
          "resources" => [res("A", declared("session", "enforced"))],
          "edges" => [edge("http_boundary", "C", "https://api.x.com", [3])]
        })

      result = Diff.compute(nil, candidate)

      assert result.baseline_present == false
      assert result.removed == []
      assert result.changed == []
      assert result.location_only == []
      assert ids(result.added) == ["edge:http_boundary:C=>https://api.x.com", "res:A"]
    end
  end

  describe "schema_version mismatch" do
    test "raises a clear error when the two models disagree on schema_version" do
      baseline = model(%{"schema_version" => 1})
      candidate = model(%{"schema_version" => 2})

      assert_raise ArchLens.Diff.SchemaMismatchError, ~r/schema_version mismatch/, fn ->
        Diff.compute(baseline, candidate)
      end
    end
  end

  describe "input canonicalization" do
    test "atom-keyed models and their JSON round-trip diff identically" do
      atom_baseline = %{
        schema_version: 1,
        resources: [
          %{
            id: "res:A",
            module: "A",
            source: "declared",
            privacy: %{
              posture: "declared",
              data_category: :session,
              retention: %{enforcement: "enforced"}
            }
          }
        ],
        edges: [],
        oban_workers: [],
        external_systems: [],
        runtime_components: [],
        entry_points: [],
        declared_architecture: []
      }

      atom_candidate =
        put_in(atom_baseline, [:resources, Access.at(0), :privacy, :data_category], :biometric)

      json_baseline = atom_baseline |> Jason.encode!() |> Jason.decode!()
      json_candidate = atom_candidate |> Jason.encode!() |> Jason.decode!()

      assert Diff.compute(atom_baseline, atom_candidate) ==
               Diff.compute(json_baseline, json_candidate)

      changed = find(Diff.compute(atom_candidate, atom_baseline).changed, "res:A")

      assert %{field: "privacy.data_category", before: "biometric", after: "session"} in changed.changes
    end
  end

  # --- declared architecture (structured map, not a list) -----------------

  describe "declared_architecture actors and contexts are diffed" do
    test "declared actors and contexts partition into added / removed / changed by stable id" do
      baseline =
        model(%{
          "declared_architecture" =>
            declared_arch(
              [actor("developer", "captures annotations", ["browser"])],
              [declared_context("accounts", "users", "MyApp.Accounts")]
            )
        })

      candidate =
        model(%{
          "declared_architecture" =>
            declared_arch(
              [
                actor("developer", "captures and triages annotations", ["browser"]),
                actor("admin", "manages workspaces", ["browser"])
              ],
              []
            )
        })

      result = Diff.compute(baseline, candidate)

      assert ids(result.added) == ["decl:actor:admin"]
      assert ids(result.removed) == ["decl:context:accounts"]
      assert ids(result.changed) == ["decl:actor:developer"]

      changed = find(result.changed, "decl:actor:developer")

      assert %{
               field: "does",
               before: "captures annotations",
               after: "captures and triages annotations"
             } in changed.changes
    end

    test "nil baseline reports declared actors and contexts as added" do
      candidate =
        model(%{
          "declared_architecture" =>
            declared_arch(
              [actor("developer", "captures annotations", ["browser"])],
              [declared_context("accounts", "users", "MyApp.Accounts")]
            )
        })

      result = Diff.compute(nil, candidate)

      assert "decl:actor:developer" in ids(result.added)
      assert "decl:context:accounts" in ids(result.added)
    end

    test "an empty structured declared_architecture contributes no deltas" do
      baseline = model(%{"declared_architecture" => declared_arch([], [])})
      candidate = model(%{"declared_architecture" => declared_arch([], [])})

      result = Diff.compute(baseline, candidate)

      assert result.added == []
      assert result.removed == []
      assert result.changed == []
    end
  end

  # --- warnings surface ---------------------------------------------------

  describe "warnings/1 and warning_count/1" do
    test "collect warn deltas across added, removed and changed" do
      baseline = model(%{"resources" => [res("X", declared("session", "enforced"))]})

      candidate =
        model(%{
          "resources" => [res("X", declared("session", "declared_not_enforced"))],
          "edges" => [edge("http_boundary", "C", "https://api.x.com", [3])]
        })

      result = Diff.compute(baseline, candidate)

      assert Diff.warning_count(result) == 2
      assert ids(Diff.warnings(result)) == ["edge:http_boundary:C=>https://api.x.com", "res:X"]
    end
  end
end
