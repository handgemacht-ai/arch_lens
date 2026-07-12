defmodule ArchLens.Generator.Sections.DecisionsTest do
  use ExUnit.Case, async: true

  alias ArchLens.Generator.Sections.Decisions

  # Elements as `ArchLens.Collect.Decisions.scan/1` produces them (atom keys); the
  # model runs them through `to_json/1` before the document renders them.
  defp element(number, slug, title, status, date) do
    %{
      id: "adr:" <> number,
      number: number,
      slug: slug,
      title: title,
      status: status,
      date: date,
      source: "declared",
      path: "docs/decisions/#{number}-#{slug}.md"
    }
  end

  describe "heading/0" do
    test "is the Decisions heading" do
      assert Decisions.heading() == "## Decisions"
    end
  end

  describe "to_json/1" do
    test "stringifies keys and sorts by number" do
      json =
        Decisions.to_json([
          element("0002", "second", "Second", "proposed", "2026-02-02"),
          element("0001", "first", "First", "accepted", "2026-01-01")
        ])

      assert Enum.map(json, & &1["number"]) == ["0001", "0002"]

      assert Enum.at(json, 0) == %{
               "id" => "adr:0001",
               "number" => "0001",
               "slug" => "first",
               "title" => "First",
               "status" => "accepted",
               "date" => "2026-01-01",
               "source" => "declared",
               "path" => "docs/decisions/0001-first.md"
             }
    end

    test "an empty list stays empty" do
      assert Decisions.to_json([]) == []
    end
  end

  describe "render/1" do
    test "renders nothing for an app with no decisions" do
      assert Decisions.render([]) == []
    end

    test "renders the heading, a blank line, and one bullet per decision, number-sorted" do
      entries =
        Decisions.to_json([
          element(
            "0002",
            "mcp-stays-custom",
            "MCP stays a hand-written controller",
            "accepted",
            "2026-06-20"
          ),
          element(
            "0001",
            "rest-api-ashjsonapi",
            "Consolidate the REST API on AshJsonApi",
            "accepted",
            "2026-06-15"
          )
        ])

      assert Decisions.render(entries) == [
               "## Decisions",
               "",
               "- **ADR-0001** Consolidate the REST API on AshJsonApi — _accepted_ (2026-06-15) `docs/decisions/0001-rest-api-ashjsonapi.md`",
               "- **ADR-0002** MCP stays a hand-written controller — _accepted_ (2026-06-20) `docs/decisions/0002-mcp-stays-custom.md`"
             ]
    end

    test "a retired decision still renders with its status verbatim" do
      entries =
        Decisions.to_json([
          element("0005", "old-choice", "An old choice", "superseded", "2025-01-01")
        ])

      assert Decisions.render(entries) == [
               "## Decisions",
               "",
               "- **ADR-0005** An old choice — _superseded_ (2025-01-01) `docs/decisions/0005-old-choice.md`"
             ]
    end
  end
end
