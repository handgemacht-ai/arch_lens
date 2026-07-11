defmodule ArchLens.ModuleDocFixtures do
  @moduledoc """
  Realistically compiled fixture modules for the `doc` collection.

  These are real modules compiled to disk under `test/support`, so
  `Code.fetch_docs/1` reads them from an actual beam docs chunk — a module defined
  inline in a `_test.exs` does not reliably carry one, which is exactly the
  hand-crafted-fixture trap the v2 review flagged. Each fixture pins one extraction
  case: a multi-paragraph moduledoc (only the first paragraph is collected),
  `@moduledoc false`, no moduledoc attribute at all, a single paragraph that spans
  several source lines, and light markdown (inline code + a link) to strip.
  """

  defmodule MultiParagraph do
    @moduledoc """
    Collects semantic review findings and writes them back to the annotation.

    A second paragraph documenting internal scheduling that the architecture
    summary must never surface.

    A third paragraph, also dropped.
    """
  end

  defmodule DocFalse do
    @moduledoc false
  end

  # credo:disable-for-next-line Credo.Check.Readability.ModuleDoc
  defmodule NoDoc do
    # Deliberately carries no @moduledoc attribute — the "field absent" case.
    @doc false
    def noop, do: :ok
  end

  defmodule MultilineParagraph do
    @moduledoc """
    First line of one paragraph
    that continues across three
    source lines without a blank line.

    Dropped tail paragraph.
    """
  end

  defmodule Markdowny do
    @moduledoc """
    Wraps the `Stripe` client and posts to [the billing API](https://api.stripe.com).
    """
  end
end
