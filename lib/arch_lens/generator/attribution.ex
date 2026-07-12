defmodule ArchLens.Generator.Attribution do
  @moduledoc """
  Attributes each entry point to its bounded context, stamping `context` and
  `context_basis` on every entry-point element.

  `attribute/2` runs in `ArchLens.Generator.Model.to_map/1` after `Contexts.resolve`
  and before the entry points serialise, so the flat, complete, gate-able entry-point
  inventory carries a per-element context without being fragmented into contexts.

  A handler is attributed by one of two rules, honest by construction and never
  fuzzy (a `HaviWeb.WorkspaceController` is *not* guessed into a `workspace`
  context — workspaces live in `accounts`):

    * **declared interface** (precedence): a context declares, via the `interface`
      option on `ArchLens.Domain` / `ArchLens.Context`, the handler-module namespace
      prefixes it serves. This is the human-asserted bridge across the web↔domain
      boundary — necessary because web handlers live under `*Web.*`, never under the
      domain namespace. Basis: `declared by context <name>`.
    * **namespace containment**: the handler equals the context's root module or is
      nested under it (`<module>.`), longest prefix wins. This auto-attributes
      co-located handlers such as cron/worker entries under a `*.Workers` context.
      Basis: `namespace containment (<module>)`.

  When neither rule fires the element's `context` is `nil` (rendered "Unattributed",
  never guessed) and no `context_basis` is stamped. Elements without a `handler`
  (e.g. a hand-supplied `%{label: …}`) pass through untouched, so a caller's
  synthetic entry is never rewritten.
  """

  alias ArchLens.Context.Info, as: ContextInfo
  alias ArchLens.Domain
  alias ArchLens.Edge

  @doc "Stamp `context`/`context_basis` on each entry point in `entry_points`."
  @spec attribute([map()], [map()]) :: [map()]
  def attribute(entry_points, contexts) do
    index = index(contexts)
    Enum.map(entry_points, &attribute_entry(&1, index))
  end

  defp attribute_entry(entry, index) when is_map(entry) do
    if Map.has_key?(entry, :handler) do
      case match(entry.handler, index) do
        {name, basis} -> entry |> Map.put(:context, name) |> Map.put(:context_basis, basis)
        nil -> Map.put(entry, :context, nil)
      end
    else
      entry
    end
  end

  defp attribute_entry(entry, _index), do: entry

  # A normalized, name-sorted view of the contexts: name string, declared interface
  # prefixes, and the root module name (nil for a central declaration with no module).
  defp index(contexts) do
    contexts
    |> Enum.map(fn context ->
      %{
        name: to_string(context.name),
        interfaces: interfaces(context),
        module: module_name(context)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp interfaces(%{origin: :domain, module: module}) when is_atom(module),
    do: Domain.interface(module)

  defp interfaces(%{origin: :context_module, module: module}) when is_atom(module),
    do: ContextInfo.interface(module)

  defp interfaces(_context), do: []

  defp module_name(%{module: module}) when is_atom(module) and not is_nil(module),
    do: Edge.module_name(module)

  defp module_name(_context), do: nil

  defp match(handler, _index) when not is_binary(handler), do: nil

  defp match(handler, index) do
    case Enum.flat_map(index, &candidates(&1, handler)) do
      [] ->
        nil

      candidates ->
        %{name: name, basis: basis} =
          Enum.min_by(candidates, fn c -> {c.priority, -c.length, c.name} end)

        {name, basis}
    end
  end

  defp candidates(context, handler) do
    interface_candidates(context, handler) ++ containment_candidate(context, handler)
  end

  defp interface_candidates(context, handler) do
    context.interfaces
    |> Enum.filter(&prefix_match?(handler, &1))
    |> Enum.map(fn prefix ->
      %{
        priority: 0,
        length: String.length(prefix),
        name: context.name,
        basis: "declared by context " <> context.name
      }
    end)
  end

  defp containment_candidate(%{module: nil}, _handler), do: []

  defp containment_candidate(context, handler) do
    if prefix_match?(handler, context.module) do
      [
        %{
          priority: 1,
          length: String.length(context.module),
          name: context.name,
          basis: "namespace containment (" <> context.module <> ")"
        }
      ]
    else
      []
    end
  end

  defp prefix_match?(handler, prefix) do
    handler == prefix or String.starts_with?(handler, prefix <> ".")
  end
end
