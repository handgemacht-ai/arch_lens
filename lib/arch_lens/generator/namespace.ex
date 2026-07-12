defmodule ArchLens.Generator.Namespace do
  @moduledoc """
  Shared namespace logic over a resolved `ArchLens.Generator.Scope`.

  Two concerns live here, in one place, so the style gate, the annotation gate, and
  the cross-context attribution (dependency edges, entry points, flow membership) all
  read the same segment rules:

    * **folder namespaces** — `folder_namespaces/1` yields the top-level directory
      segments under the app namespace that actually have children, minus the ones
      named in `ignore_namespaces`; `root_module/2` names the root module a segment
      is expected to carry. `ArchLens.Generator.Contexts` drives its style gate off
      these.
    * **module attribution** — `context_index/2` folds a scope and its resolved
      contexts into a total attributor; `attribute/2` maps one module to its owning
      context name (or `nil`); `membership/1` materialises the whole
      `module => context name` map. A childless annotated context owns only its exact
      module; a folder-root or domain context owns its whole top-level segment, and an
      exact-module match wins over a segment match.

  A module whose segment carries no context, or which sits outside the app namespace,
  attributes to `nil` — never a guessed context.
  """

  alias ArchLens.Generator.Scope

  @typedoc """
  The attributor `context_index/2` builds: a segment-keyed map for folder-root and
  domain contexts, an exact-module map for childless contexts, plus the app namespace
  and module list `attribute/2` and `membership/1` read.
  """
  @type index :: %{
          app_namespace: module() | nil,
          segments: %{String.t() => atom()},
          exact: %{module() => atom()},
          modules: [module()]
        }

  @doc """
  The top-level directory segments under the app namespace that actually have
  children — a segment `Seg` such that some module is `<App>.Seg.X...`. Ignored
  segments (`ignore_namespaces`) are dropped. Segments are strings, sorted.
  """
  @spec folder_namespaces(Scope.t()) :: [String.t()]
  def folder_namespaces(%Scope{app_namespace: app_ns, modules: modules} = scope) do
    base = base_segments(app_ns)

    modules
    |> Enum.flat_map(&child_segment(base, &1))
    |> Enum.uniq()
    |> Enum.reject(&ignored?(&1, scope.ignore_namespaces))
    |> Enum.sort()
  end

  @doc "The root module `<App>.<segment>` a folder namespace is expected to carry."
  @spec root_module(Scope.t(), String.t()) :: module()
  def root_module(%Scope{app_namespace: app_ns}, segment), do: Module.concat([app_ns, segment])

  @doc """
  Fold `scope` and its already-resolved `contexts` into a total module attributor.

  A context whose top-level segment has children (a domain or folder-root context)
  claims that whole segment; a childless annotated context claims only its exact
  module. Contexts with no resolvable module (a deprecated central declaration) are
  skipped.
  """
  @spec context_index(Scope.t(), [map()]) :: index()
  def context_index(%Scope{} = scope, contexts) when is_list(contexts) do
    folder_ns = MapSet.new(folder_namespaces(scope))
    base = base_segments(scope.app_namespace)

    {segments, exact} =
      Enum.reduce(contexts, {%{}, %{}}, fn context, acc ->
        context |> classify(base, folder_ns) |> fold_classification(acc)
      end)

    %{
      app_namespace: scope.app_namespace,
      segments: segments,
      exact: exact,
      modules: scope.modules
    }
  end

  @doc """
  The context name owning `module`, or `nil`.

  An exact-module match (a childless context) wins; otherwise the module's top-level
  segment is looked up (a domain or folder-root context).
  """
  @spec attribute(index(), module()) :: atom() | nil
  def attribute(%{exact: exact} = index, module) do
    case Map.fetch(exact, module) do
      {:ok, name} ->
        name

      :error ->
        case top_segment(base_segments(index.app_namespace), module) do
          segment when is_binary(segment) -> Map.get(index.segments, segment)
          nil -> nil
        end
    end
  end

  @doc """
  The `module => context name` map for every scope module that attributes to a
  context. Unattributed modules are absent, never mapped to `nil`.
  """
  @spec membership(index()) :: %{module() => atom()}
  def membership(%{modules: modules} = index) do
    for module <- modules,
        name = attribute(index, module),
        not is_nil(name),
        into: %{},
        do: {module, name}
  end

  # --- internal segment analysis ------------------------------------------

  # Classify one resolved context into how it attributes modules: a whole top-level
  # segment (domain / folder-root), its exact module (childless), or nothing (a
  # central declaration with no resolvable module).
  defp classify(context, base, folder_ns) do
    case Map.get(context, :module) do
      nil -> :skip
      module -> classify_module(module, context.name, base, folder_ns)
    end
  end

  defp classify_module(module, name, base, folder_ns) do
    segment = top_segment(base, module)

    if is_binary(segment) and MapSet.member?(folder_ns, segment) do
      {:segment, segment, name}
    else
      {:exact, module, name}
    end
  end

  defp fold_classification(:skip, acc), do: acc

  defp fold_classification({:segment, segment, name}, {segments, exact}),
    do: {Map.put_new(segments, segment, name), exact}

  defp fold_classification({:exact, module, name}, {segments, exact}),
    do: {segments, Map.put(exact, module, name)}

  defp base_segments(nil), do: nil
  defp base_segments(app_ns), do: Module.split(app_ns)

  defp top_segment(base, module) do
    case remainder(base, module) do
      [segment | _] -> segment
      _ -> nil
    end
  end

  defp child_segment(base, module) do
    case remainder(base, module) do
      [segment, _ | _] -> [segment]
      _ -> []
    end
  end

  defp remainder(nil, _module), do: nil

  defp remainder(base, module) do
    segments = Module.split(module)
    if List.starts_with?(segments, base), do: Enum.drop(segments, length(base)), else: nil
  end

  defp ignored?(segment, ignore_namespaces) do
    normalized = normalize_namespace(segment)
    Enum.any?(ignore_namespaces, &(normalize_namespace(&1) == normalized))
  end

  # Fold both an `ignore_namespaces` entry and a directory segment to a form that
  # ignores internal underscore boundaries, so the intuitive `:e2e` matches the
  # `E2E` segment that `Macro.underscore/1` would otherwise render as `:e2_e`.
  defp normalize_namespace(value) do
    value |> to_string() |> Macro.underscore() |> String.replace("_", "")
  end
end
