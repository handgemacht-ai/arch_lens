defmodule ArchLens.Collect.DecisionsTest do
  use ExUnit.Case, async: true

  alias ArchLens.Collect.Decisions

  @ok_dir "test/fixtures/decisions_ok"
  @bad_dir "test/fixtures/decisions_bad"

  defp write!(dir, name, content), do: File.write!(Path.join(dir, name), content)

  describe "committed fixtures" do
    test "the ok fixture indexes one well-formed decision with verbatim front-matter" do
      assert %{decisions: [decision], errors: []} = Decisions.scan(@ok_dir)

      assert decision == %{
               id: "adr:0001",
               number: "0001",
               slug: "example",
               title: "Consolidate the REST API on AshJsonApi",
               status: "accepted",
               date: "2026-06-15",
               source: "declared",
               path: "test/fixtures/decisions_ok/0001-example.md"
             }
    end

    test "the bad fixture reports the missing required key and indexes nothing" do
      assert %{decisions: [], errors: [{path, reason}]} = Decisions.scan(@bad_dir)
      assert path == "test/fixtures/decisions_bad/0001-missing-status.md"
      assert reason == "missing required key `status`"
    end
  end

  describe "empty states (gate passes vacuously)" do
    test "a missing directory is not an error" do
      assert Decisions.scan("test/fixtures/decisions_does_not_exist") ==
               %{decisions: [], errors: []}
    end

    test "false disables indexing" do
      assert Decisions.scan(false) == %{decisions: [], errors: []}
    end

    test "nil resolves to the default docs/decisions directory" do
      assert %{decisions: _, errors: _} = Decisions.scan(nil)
    end

    @tag :tmp_dir
    test "an empty directory yields no decisions and no errors", %{tmp_dir: dir} do
      assert Decisions.scan(dir) == %{decisions: [], errors: []}
    end
  end

  describe "reserved-filename escape hatch" do
    @tag :tmp_dir
    test "README.md, template.md and 0000-template.md are skipped, not errors", %{tmp_dir: dir} do
      write!(dir, "README.md", "# Decisions index\n")
      write!(dir, "template.md", "---\ntitle: t\n---\n")
      write!(dir, "0000-template.md", "---\ntitle: t\nstatus: accepted\ndate: 2026-01-01\n---\n")

      assert Decisions.scan(dir) == %{decisions: [], errors: []}
    end
  end

  describe "filename grammar" do
    @tag :tmp_dir
    test "a non-conforming .md filename is a per-file error", %{tmp_dir: dir} do
      write!(dir, "1-too-short.md", valid_front_matter())
      write!(dir, "notes.md", valid_front_matter())

      assert %{decisions: [], errors: errors} = Decisions.scan(dir)
      reasons = Enum.map(errors, fn {_path, reason} -> reason end)
      assert Enum.all?(reasons, &(&1 =~ "filename must match NNNN-slug.md"))
      assert length(errors) == 2
    end

    @tag :tmp_dir
    test "non-markdown files in the directory are ignored", %{tmp_dir: dir} do
      write!(dir, "0001-real.md", valid_front_matter())
      write!(dir, "notes.txt", "not an adr")
      write!(dir, ".gitkeep", "")

      assert %{decisions: [decision], errors: []} = Decisions.scan(dir)
      assert decision.number == "0001"
    end
  end

  describe "front-matter tolerance (no YAML dependency)" do
    @tag :tmp_dir
    test "a BOM, CRLF line endings and quoted values all parse", %{tmp_dir: dir} do
      bom = <<0xEF, 0xBB, 0xBF>>

      content =
        bom <>
          "---\r\n" <>
          "title: \"A quoted, comma-bearing title\"\r\n" <>
          "status: 'accepted'\r\n" <>
          "date: 2026-06-15\r\n" <>
          "---\r\n\r\nBody.\r\n"

      write!(dir, "0007-tolerant.md", content)

      assert %{decisions: [decision], errors: []} = Decisions.scan(dir)
      assert decision.title == "A quoted, comma-bearing title"
      assert decision.status == "accepted"
      assert decision.date == "2026-06-15"
    end

    @tag :tmp_dir
    test "unknown keys are tolerated and ignored", %{tmp_dir: dir} do
      content =
        "---\ntitle: Has extras\nstatus: proposed\ndate: 2026-02-02\n" <>
          "deciders: alice, bob\ntags: [rest, api]\n---\n\nBody.\n"

      write!(dir, "0002-extras.md", content)

      assert %{decisions: [decision], errors: []} = Decisions.scan(dir)
      assert decision.title == "Has extras"
      assert decision.status == "proposed"
    end
  end

  describe "validity errors" do
    @tag :tmp_dir
    test "missing the front-matter fence is an error", %{tmp_dir: dir} do
      write!(dir, "0001-no-fence.md", "# Just a heading\n\nNo front matter here.\n")

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason =~ "missing front-matter block"
    end

    @tag :tmp_dir
    test "an unterminated front-matter block is an error", %{tmp_dir: dir} do
      write!(dir, "0001-unterminated.md", "---\ntitle: t\nstatus: accepted\ndate: 2026-01-01\n")

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason =~ "unterminated front-matter block"
    end

    @tag :tmp_dir
    test "a status outside the closed enum is an error", %{tmp_dir: dir} do
      write!(dir, "0001-bad-status.md", "---\ntitle: t\nstatus: maybe\ndate: 2026-01-01\n---\n")

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason =~ "invalid `status`"
    end

    @tag :tmp_dir
    test "a non-ISO date is an error", %{tmp_dir: dir} do
      write!(dir, "0001-bad-date.md", "---\ntitle: t\nstatus: accepted\ndate: 15/06/2026\n---\n")

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason =~ "invalid `date`"
    end

    @tag :tmp_dir
    test "a real-but-impossible date is an error", %{tmp_dir: dir} do
      write!(dir, "0001-feb30.md", "---\ntitle: t\nstatus: accepted\ndate: 2026-02-30\n---\n")

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason =~ "invalid `date`"
    end

    @tag :tmp_dir
    test "a blank title is an error, distinct from a missing key", %{tmp_dir: dir} do
      write!(
        dir,
        "0001-blank-title.md",
        "---\ntitle:   \nstatus: accepted\ndate: 2026-01-01\n---\n"
      )

      assert %{decisions: [], errors: [{_path, reason}]} = Decisions.scan(dir)
      assert reason == "blank `title`"
    end
  end

  describe "duplicate numbers" do
    @tag :tmp_dir
    test "two files sharing an ADR number are both flagged and neither is indexed", %{
      tmp_dir: dir
    } do
      write!(dir, "0001-first.md", valid_front_matter())
      write!(dir, "0001-second.md", valid_front_matter())

      assert %{decisions: [], errors: errors} = Decisions.scan(dir)
      assert length(errors) == 2

      assert Enum.all?(errors, fn {_path, reason} ->
               reason =~ "duplicate decision number 0001"
             end)
    end
  end

  describe "determinism" do
    @tag :tmp_dir
    test "decisions are sorted by number regardless of directory order", %{tmp_dir: dir} do
      write!(dir, "0003-c.md", valid_front_matter())
      write!(dir, "0001-a.md", valid_front_matter())
      write!(dir, "0002-b.md", valid_front_matter())

      assert %{decisions: decisions, errors: []} = Decisions.scan(dir)
      assert Enum.map(decisions, & &1.number) == ["0001", "0002", "0003"]
    end

    @tag :tmp_dir
    test "errors are sorted by path", %{tmp_dir: dir} do
      write!(dir, "bbb.md", valid_front_matter())
      write!(dir, "aaa.md", valid_front_matter())

      assert %{decisions: [], errors: errors} = Decisions.scan(dir)
      paths = Enum.map(errors, fn {path, _reason} -> path end)
      assert paths == Enum.sort(paths)
    end
  end

  defp valid_front_matter do
    "---\ntitle: A valid decision\nstatus: accepted\ndate: 2026-06-15\n---\n\nBody.\n"
  end
end
