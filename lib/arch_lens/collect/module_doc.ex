defmodule ArchLens.Collect.ModuleDoc do
  @moduledoc """
  Surfaces a module's own `@moduledoc` first paragraph for the generator's
  optional `doc` field.

  Honest by construction: `first_paragraph/1` returns the verbatim first paragraph
  of a module's moduledoc (the text up to the first blank line), whitespace-
  normalised to a single line and lightly de-marked-down (inline `code` and
  `[label](url)` links reduced to their text), or `nil` when the moduledoc is
  missing, `@moduledoc false`, or the module carries no docs chunk. It never
  summarises, rewrites, or substitutes any other text — an absent doc stays absent.

  The paragraph is read from compiled beam metadata via `Code.fetch_docs/1`, so
  the same compiled module yields the same paragraph on every run and machine.
  """

  @doc """
  The first paragraph of `module`'s `@moduledoc`, whitespace-normalised to a
  single line, or `nil` when there is nothing to surface honestly.

  Anything that is not a real, doc-carrying module — a non-atom, `nil`/`true`/
  `false`, an atom that is not a loaded module, or a module with no moduledoc —
  yields `nil` so callers can drop the field.
  """
  @spec first_paragraph(term()) :: String.t() | nil
  def first_paragraph(module) when is_atom(module) and module not in [nil, true, false] do
    module
    |> moduledoc()
    |> paragraph()
  end

  def first_paragraph(_other), do: nil

  @doc """
  The first sentence of an already-extracted `paragraph`, for the tight Markdown
  rendering (the JSON sidecar keeps the whole paragraph).

  Text up to and including the first `.`, `!`, or `?` that is followed by
  whitespace or the end of the string; falls back to the whole paragraph when no
  such terminator is found. `nil` in, `nil` out.
  """
  @spec first_sentence(String.t() | nil) :: String.t() | nil
  def first_sentence(nil), do: nil

  def first_sentence(paragraph) when is_binary(paragraph) do
    case Regex.run(~r/^.*?[.!?](?=\s|$)/u, paragraph) do
      [sentence] -> sentence
      _ -> paragraph
    end
  end

  defp moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, doc, _meta, _docs} -> doc
      _ -> :none
    end
  rescue
    _ -> :none
  end

  # `:none` (no `@moduledoc`), `:hidden` (`@moduledoc false`), or any non-map is
  # an absent doc — never fabricated into a fallback string.
  defp paragraph(doc) when is_map(doc) do
    doc
    |> localized()
    |> extract_first_paragraph()
  end

  defp paragraph(_absent), do: nil

  defp localized(doc) do
    case Map.get(doc, "en") do
      text when is_binary(text) -> text
      _ -> first_binary_value(doc)
    end
  end

  defp first_binary_value(doc) do
    doc
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.find_value(fn {_key, value} -> binary_or_nil(value) end)
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp extract_first_paragraph(nil), do: nil

  defp extract_first_paragraph(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.trim_leading()
    |> String.split(~r/\n[ \t]*\n/, parts: 2)
    |> List.first()
    |> strip_markdown()
    |> collapse_whitespace()
    |> blank_to_nil()
  end

  defp strip_markdown(text) do
    text
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/`([^`]+)`/, "\\1")
  end

  defp collapse_whitespace(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
