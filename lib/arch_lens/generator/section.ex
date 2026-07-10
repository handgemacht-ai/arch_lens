defmodule ArchLens.Generator.Section do
  @moduledoc """
  Shared contract for the optional generator sections (the follow-up-slice seams).

  Each seam field on `ArchLens.Generator.Scope` (`entry_points`,
  `runtime_components`, `external_systems`, `declared_architecture`) is rendered by
  one section module implementing this behaviour, so a follow-up slice fills in a
  single, disjoint file. `render/1` yields the Markdown lines (or `[]` to render
  nothing when the field is empty); `to_json/1` yields the JSON-model entries.

  The `bullet/1` and `jsonable/1` helpers give the stub implementations a shared,
  deterministic default a slice can keep or replace.
  """

  @doc "The Markdown heading for the section."
  @callback heading() :: String.t()

  @doc "Markdown lines for the section, or `[]` when there is nothing to render."
  @callback render(entries :: [term()]) :: [String.t()]

  @doc "JSON-model entries for the section (JSON-safe maps/scalars)."
  @callback to_json(entries :: [term()]) :: [term()]

  @doc """
  A deterministic Markdown bullet for a seam entry.

  Prefers an entry's `label` (string or atom key), falling back to `inspect/1`.
  """
  @spec bullet(term()) :: String.t()
  def bullet(entry) when is_map(entry) do
    label = entry["label"] || entry[:label] || inspect(entry)
    "- #{label}"
  end

  def bullet(entry), do: "- #{inspect(entry)}"

  @doc """
  Coerce a seam entry into a JSON-safe value: stringifies atom keys, canonicalises
  module/atom values (`Elixir.` prefix stripped), and recurses through maps/lists.
  """
  @spec jsonable(term()) :: term()
  def jsonable(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, val} -> {jsonable_key(key), jsonable(val)} end)
  end

  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  def jsonable(value) when is_atom(value) and value not in [nil, true, false],
    do: atom_string(value)

  def jsonable(value), do: value

  defp jsonable_key(key) when is_atom(key) and key not in [nil, true, false], do: atom_string(key)
  defp jsonable_key(key), do: key

  defp atom_string(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end
end
