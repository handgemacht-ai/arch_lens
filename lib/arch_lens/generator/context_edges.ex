defmodule ArchLens.Generator.ContextEdges do
  @moduledoc """
  Aggregates raw cross-module references (`ArchLens.Collect.Dependencies`) into
  cross-context dependency edges, attributing each endpoint to its bounded context
  through the `ArchLens.Generator.Namespace` attributor.

  `build/2` maps every reference's endpoints to their owning contexts, drops the
  reference when either endpoint attributes to no context (an excluded context, an
  `ignore_namespaces` segment, or app-root infra) or both endpoints land in the same
  context (a within-context reference is not a cross-context edge), groups the survivors
  by `{from_context, to_context}`, and emits one deterministic element per group:

      %{
        id: "ctxdep:<from>-><to>",
        kind: "context_dependency",
        source: "collected",
        from: <from context name>,
        to: <to context name>,
        reference_count: <count of distinct caller modules in the source context>,
        sample: %{from_module, to_module, file, line?}
      }

  `reference_count` is the number of distinct caller modules in the source context that
  reference the target context. `sample` is the single deterministic representative:
  the minimum `{from_module, to_module, file, line}` call site across the group (its
  `line` is present only when a line was resolved). Edges sort by `{from, to}`, so
  generating twice from unchanged code is byte-identical.
  """

  alias ArchLens.Edge
  alias ArchLens.Generator.Namespace

  @doc "Cross-context dependency edges for `refs`, attributed through `index`."
  @spec build([map()], Namespace.index()) :: [map()]
  def build(refs, index) do
    refs
    |> Enum.flat_map(&attribute(&1, index))
    |> Enum.group_by(&{&1.from, &1.to})
    |> Enum.map(fn {{from, to}, tuples} -> edge(from, to, tuples) end)
    |> Enum.sort_by(& &1.id)
  end

  # Expand one raw reference into its per-call-site tuples, each stamped with the
  # attributed source and target contexts. Yields nothing when either endpoint is
  # unattributed or the reference stays within one context.
  defp attribute(%{from_module: from_module, to_module: to_module, call_sites: sites}, index) do
    from = Namespace.attribute(index, from_module)
    to = Namespace.attribute(index, to_module)

    if cross_context?(from, to) do
      Enum.map(sites, &tuple(from, to, from_module, to_module, &1))
    else
      []
    end
  end

  defp cross_context?(from, to), do: not is_nil(from) and not is_nil(to) and from != to

  defp tuple(from, to, from_module, to_module, site) do
    %{
      from: to_string(from),
      to: to_string(to),
      from_module: Edge.module_name(from_module),
      to_module: Edge.module_name(to_module),
      file: site.file,
      line: Map.get(site, :line)
    }
  end

  defp edge(from, to, tuples) do
    %{
      id: "ctxdep:#{from}->#{to}",
      kind: "context_dependency",
      source: "collected",
      from: from,
      to: to,
      reference_count: reference_count(tuples),
      sample: sample(tuples)
    }
  end

  defp reference_count(tuples) do
    tuples |> Enum.map(& &1.from_module) |> Enum.uniq() |> length()
  end

  # The deterministic representative: the minimum call site by
  # {from_module, to_module, file, line}, preferring a resolved line over none.
  defp sample(tuples) do
    tuple = Enum.min_by(tuples, &sort_key/1)

    %{from_module: tuple.from_module, to_module: tuple.to_module, file: tuple.file}
    |> maybe_put(:line, tuple.line)
  end

  defp sort_key(%{from_module: from_module, to_module: to_module, file: file, line: line}) do
    {from_module, to_module, file, line_key(line)}
  end

  defp line_key(nil), do: {1, 0}
  defp line_key(line), do: {0, line}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
