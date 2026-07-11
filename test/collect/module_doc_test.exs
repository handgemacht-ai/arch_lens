defmodule ArchLens.Collect.ModuleDocTest do
  # async: false — reads compiled beam docs chunks; keep serialized with the rest
  # of the collect suite for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.ModuleDoc
  alias ArchLens.ModuleDocFixtures

  describe "first_paragraph/1 — realistically compiled fixtures" do
    test "collects only the first paragraph of a multi-paragraph moduledoc" do
      assert ModuleDoc.first_paragraph(ModuleDocFixtures.MultiParagraph) ==
               "Collects semantic review findings and writes them back to the annotation."
    end

    test "a single paragraph spanning several source lines normalises to one line" do
      assert ModuleDoc.first_paragraph(ModuleDocFixtures.MultilineParagraph) ==
               "First line of one paragraph that continues across three source lines without a blank line."
    end

    test "@moduledoc false yields nil (field absent)" do
      assert ModuleDoc.first_paragraph(ModuleDocFixtures.DocFalse) == nil
    end

    test "a module with no moduledoc attribute yields nil (field absent)" do
      assert ModuleDoc.first_paragraph(ModuleDocFixtures.NoDoc) == nil
    end

    test "lightly strips inline code and link syntax, verbatim otherwise" do
      assert ModuleDoc.first_paragraph(ModuleDocFixtures.Markdowny) ==
               "Wraps the Stripe client and posts to the billing API."
    end
  end

  describe "first_paragraph/1 — honest absence, never fabricated" do
    test "an atom that is not a loaded module yields nil" do
      assert ModuleDoc.first_paragraph(:definitely_not_a_module) == nil
      assert ModuleDoc.first_paragraph(Elixir.ArchLens.Nope.Missing) == nil
    end

    test "nil, booleans, and non-atoms yield nil" do
      assert ModuleDoc.first_paragraph(nil) == nil
      assert ModuleDoc.first_paragraph(true) == nil
      assert ModuleDoc.first_paragraph("not an atom") == nil
      assert ModuleDoc.first_paragraph(42) == nil
    end
  end

  describe "first_paragraph/1 — determinism" do
    test "the same compiled module yields the identical paragraph across calls" do
      first = ModuleDoc.first_paragraph(ModuleDocFixtures.MultiParagraph)
      second = ModuleDoc.first_paragraph(ModuleDocFixtures.MultiParagraph)
      assert first == second
    end
  end

  describe "first_sentence/1 — tight markdown rendering" do
    test "returns text up to the first sentence terminator" do
      paragraph = "Collects findings and writes them back. A second sentence is dropped."
      assert ModuleDoc.first_sentence(paragraph) == "Collects findings and writes them back."
    end

    test "returns the whole paragraph when there is no terminator" do
      assert ModuleDoc.first_sentence("no terminator here") == "no terminator here"
    end

    test "nil in, nil out" do
      assert ModuleDoc.first_sentence(nil) == nil
    end
  end
end
