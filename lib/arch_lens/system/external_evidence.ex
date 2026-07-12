defmodule ArchLens.System.ExternalEvidence do
  @moduledoc """
  The single source of truth for the externals verification gates.

  Two questions have one answer here so the gate that *fails* generation and the
  stamp that *renders* the artifact can never disagree:

    * `resolve/2` — is a *declared* external corroborated by code? A declared
      external is `corroborated` when its stable id (`external:<slug(name)>`) or its
      target host matches something the collector found, or when a declared
      `evidence:` hint resolves (`dep:` names a direct dependency, `module:` a real
      app module prefix, `host:` a collected HTTP boundary). It is `manual` when the
      author supplies the escape hatch `evidence: [manual: "reason"]` (a non-empty
      reason is required). Otherwise it is `:unevidenced` — the caller
      (`ArchLens.System.Validate`) turns that into a generation-halting error. A
      declared `evidence:` hint that does not resolve is itself `:unevidenced`:
      hints must be honest.

    * `gate/1` — is every *collected* external declared? Every collector-detected
      external system must be matched by a declared `external(...)` (the same
      id/host intersection `matches?/2` uses) or listed in `ignore_externals`.
      Anything else fails the completeness gate with `{:undeclared_externals,
      vendors}`. Ignored externals are not omitted — they still render, tagged
      `verification: "ignored"`.

  `stamp/2` is the merge-time counterpart of `resolve/2`: after the gate has run,
  `ArchLens.System.ExternalMerge` trusts it and only classifies each element into
  its `verification` / `provenance` / `evidence`, synthesizing a `declared_hint`
  evidence entry for a resolved hint and a `manual` entry for the escape hatch, so
  every element carries non-empty, honest evidence.

  Everything read here is deterministic: the same declarations and collected inputs
  always produce the same verdict.
  """

  @code_hint_keys [:dep, :module, :host]

  @typedoc "A resolve context: pre-derived collected identity and hint-resolution inputs."
  @type context :: %{
          optional(:external_ids) => MapSet.t(),
          optional(:external_hosts) => MapSet.t(),
          optional(:deps) => MapSet.t(),
          optional(:known_modules) => MapSet.t()
        }

  @typedoc "A gate context: the collected externals, the declared externals, and the ignore list."
  @type gate_context :: %{
          optional(:collected) => [map()],
          optional(:declared) => [map()],
          optional(:ignore_externals) => [atom()]
        }

  @doc """
  The evidence verdict for a declared `external` in `context`.

  Returns `{:corroborated, evidence}` (implicit id/host match, or a resolved
  `dep:`/`module:`/`host:` hint), `{:manual, evidence}` (a non-empty
  `evidence: [manual: "reason"]`), or `{:unevidenced, detail}` where `detail`
  explains why (`:no_evidence`, `{:unresolved_hint, hint}`, `:empty_manual_reason`,
  `:manual_needs_reason`, or `{:unknown_hint, keys}`).
  """
  @spec resolve(map(), context()) ::
          {:corroborated, [map()]} | {:manual, [map()]} | {:unevidenced, term()}
  def resolve(external, context) do
    if implicit_match?(external, context) do
      {:corroborated, []}
    else
      resolve_hint(evidence_hint(external), context)
    end
  end

  @doc """
  The `verification` / `provenance` / `evidence` for a declared external at merge
  time, given the collected element it collapsed with (`nil` when it stands alone).

  Trusts that `resolve/2` already gated the declaration, so a present code hint is
  taken as corroborating without re-checking it against deps/modules (which the
  merge does not carry). A collapsed element carries the collected element's
  evidence; a hint-corroborated one carries the synthesized hint; a manual one
  carries the reason.
  """
  @spec stamp(map(), map() | nil) :: {String.t(), [String.t()], [map()]}
  def stamp(external, matched) do
    hint = evidence_hint(external)
    code = code_hints(hint)

    cond do
      not is_nil(matched) ->
        {"corroborated", ["collected", "declared"], collected_evidence(matched)}

      code != [] ->
        {"corroborated", ["collected", "declared"], hint_evidence(code)}

      not is_nil(manual_reason(hint)) ->
        {"manual", ["declared"], [manual_evidence(manual_reason(hint))]}

      true ->
        {"manual", ["declared"], []}
    end
  end

  @doc """
  The externals completeness gate.

  `:ok`, or `{:error, {:undeclared_externals, vendors}}` when a collected external
  system is neither matched by a declared `external(...)` (via `matches?/2`) nor
  covered by `ignore_externals`. `vendors` is sorted and de-duplicated.
  """
  @spec gate(gate_context()) :: :ok | {:error, {:undeclared_externals, [String.t()]}}
  def gate(context) do
    collected = Map.get(context, :collected, [])
    declared = Map.get(context, :declared, [])
    ignore_slugs = context |> Map.get(:ignore_externals, []) |> Enum.map(&slug/1)

    undeclared =
      collected
      |> Enum.reject(fn element -> Enum.any?(declared, &matches?(&1, element)) end)
      |> Enum.reject(&ignored?(&1, ignore_slugs))
      |> Enum.map(&vendor_label/1)
      |> Enum.uniq()
      |> Enum.sort()

    case undeclared do
      [] -> :ok
      vendors -> {:error, {:undeclared_externals, vendors}}
    end
  end

  @doc """
  Whether a declared `external` and a `collected` external system are the same third
  party — the id/host/target intersection every externals gate keys on.
  """
  @spec matches?(map(), map()) :: boolean()
  def matches?(external, collected) do
    declared = MapSet.new(declared_identity_keys(external))
    collected |> collected_identity_keys() |> Enum.any?(&MapSet.member?(declared, &1))
  end

  # --- resolve internals --------------------------------------------------------

  defp implicit_match?(external, context) do
    ids = Map.get(context, :external_ids, MapSet.new())
    hosts = Map.get(context, :external_hosts, MapSet.new())

    MapSet.member?(ids, declared_id(external)) or
      MapSet.member?(hosts, target_host(external[:target]))
  end

  defp resolve_hint(hint, context) do
    code = code_hints(hint)

    cond do
      code != [] ->
        case Enum.reject(code, &hint_resolves?(&1, context)) do
          [] -> {:corroborated, hint_evidence(code)}
          [unresolved | _] -> {:unevidenced, {:unresolved_hint, unresolved}}
        end

      Keyword.has_key?(hint, :manual) ->
        resolve_manual(Keyword.get(hint, :manual))

      hint == [] ->
        {:unevidenced, :no_evidence}

      true ->
        {:unevidenced, {:unknown_hint, unknown_hint_keys(hint)}}
    end
  end

  defp resolve_manual(reason) when is_binary(reason) do
    if String.trim(reason) == "",
      do: {:unevidenced, :empty_manual_reason},
      else: {:manual, [manual_evidence(reason)]}
  end

  defp resolve_manual(_reason), do: {:unevidenced, :manual_needs_reason}

  defp hint_resolves?({:dep, dep}, context) do
    MapSet.member?(Map.get(context, :deps, MapSet.new()), to_string(dep))
  end

  defp hint_resolves?({:module, prefix}, context) do
    module_prefix_matches?(to_string(prefix), Map.get(context, :known_modules, MapSet.new()))
  end

  defp hint_resolves?({:host, host}, context) do
    MapSet.member?(Map.get(context, :external_hosts, MapSet.new()), target_host(host))
  end

  defp hint_resolves?(_pair, _context), do: false

  defp module_prefix_matches?(prefix, known_modules) do
    Enum.any?(known_modules, fn module ->
      module == prefix or String.starts_with?(module, prefix <> ".")
    end)
  end

  defp code_hints(hint) when is_list(hint) do
    Enum.filter(hint, fn
      {key, _value} -> key in @code_hint_keys
      _other -> false
    end)
  end

  defp code_hints(_hint), do: []

  defp manual_reason(hint) when is_list(hint) do
    case Keyword.get(hint, :manual) do
      reason when is_binary(reason) -> if String.trim(reason) == "", do: nil, else: reason
      _other -> nil
    end
  end

  defp unknown_hint_keys(hint) do
    hint
    |> Enum.map(fn
      {key, _value} -> key
      other -> other
    end)
    |> Enum.reject(&(&1 in [:manual | @code_hint_keys]))
    |> Enum.uniq()
  end

  # --- evidence shapes ----------------------------------------------------------

  defp hint_evidence(code_hints) do
    Enum.map(code_hints, fn
      {:dep, dep} -> %{type: "dep", value: to_string(dep), source: "declared_hint"}
      {:module, prefix} -> %{type: "module", value: to_string(prefix), source: "declared_hint"}
      {:host, host} -> %{type: "http_boundary", value: to_string(host), source: "declared_hint"}
    end)
  end

  defp manual_evidence(reason), do: %{type: "manual", value: to_string(reason)}

  defp collected_evidence(matched) do
    case read(matched, :evidence) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  # --- identity / gate internals ------------------------------------------------

  defp declared_identity_keys(external) do
    ["id:" <> declared_id(external)] ++
      host_keys(external[:target]) ++ target_keys(external[:target])
  end

  defp collected_identity_keys(collected) do
    ["id:" <> collected_id(collected)] ++
      target_keys(read(collected, :target)) ++
      Enum.map(collected_boundary_hosts(collected), &("host:" <> &1))
  end

  defp host_keys(target) do
    case target_host(target) do
      "" -> []
      host -> ["host:" <> host]
    end
  end

  defp target_keys(target) do
    case target && String.trim_trailing(to_string(target), "/") do
      value when is_binary(value) and value != "" -> ["tgt:" <> value]
      _other -> []
    end
  end

  defp collected_boundary_hosts(collected) do
    collected
    |> read(:evidence)
    |> List.wrap()
    |> Enum.filter(fn evidence ->
      is_map(evidence) and read(evidence, :type) == "http_boundary"
    end)
    |> Enum.map(fn evidence -> target_host(read(evidence, :value)) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp ignored?(collected, ignore_slugs) do
    haystacks = collected_ignore_haystacks(collected)

    Enum.any?(ignore_slugs, fn ignore ->
      Enum.any?(haystacks, fn candidate ->
        candidate == ignore or String.starts_with?(candidate, ignore)
      end)
    end)
  end

  defp collected_ignore_haystacks(collected) do
    vendor_slug = collected |> read(:vendor) |> slug()
    id_slug = collected |> collected_id() |> String.replace_prefix("external:", "")

    dep_slugs =
      collected
      |> read(:evidence)
      |> List.wrap()
      |> Enum.filter(fn evidence -> is_map(evidence) and read(evidence, :type) == "dep" end)
      |> Enum.map(fn evidence -> evidence |> read(:value) |> slug() end)

    [vendor_slug, id_slug | dep_slugs] |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp vendor_label(collected), do: read(collected, :vendor) || collected_id(collected)

  # --- shared identity helpers --------------------------------------------------

  defp declared_id(external), do: "external:" <> slug(external[:name])

  defp collected_id(collected) do
    read(collected, :id) ||
      "external:" <>
        slug(read(collected, :vendor) || read(collected, :label) || read(collected, :name))
  end

  defp evidence_hint(external) do
    case read(external, :evidence_hint) || read(external, :evidence) do
      hint when is_list(hint) -> hint
      _other -> []
    end
  end

  # Mirrors ArchLens.Collect.Externals / ExternalMerge slugging so a declared
  # external's id lines up with the collected external system's id.
  defp slug(nil), do: ""

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp target_host(nil), do: ""

  defp target_host(target) do
    value = to_string(target)

    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> value |> String.trim() |> String.trim_trailing("/") |> String.downcase()
    end
  end

  defp read(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, to_string(key))

  defp read(_entry, _key), do: nil
end
