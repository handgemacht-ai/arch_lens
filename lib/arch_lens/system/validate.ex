defmodule ArchLens.System.Validate do
  @moduledoc """
  Reconciles a declared architecture against what the generator collected — the
  honesty gate for `ArchLens.System`, one rung above `ArchLens.Generator.Retention`.

  Three checks, run together so *all* failures are reported at once:

    1. **Actor `uses:`.** Two things are enforced. First, *vocabulary*: every atom
       an actor `uses:` must name a known entry-point kind — the canonical list the
       generator emits, `ArchLens.Collect.EntryPoints.kinds/0`
       (`:browser`, `:api`, `:webhook`, `:oauth`, `:mcp`, `:health`, `:dev`,
       `:other`), widened here with `:cron` and `:channel` for the cron and channel
       entry-point surfaces.
       An unknown atom always fails, whether or not entry points were collected.
       Second, a
       *collected cross-check*: when entry points were collected, each known kind an
       actor uses must also appear among them. Only the cross-check is skipped, with
       a recorded warning, when no entry points were collected — the vocabulary
       check still runs.
    2. **Externals.** Every declared `external(...)`, regardless of transport, must
       corroborate — delegated to `ArchLens.System.ExternalEvidence.resolve/2`. It
       is corroborated when its stable id (`external:<slug(name)>`) or its target
       host matches something the collector found (a bare name collision with an
       arbitrary dependency app is **not** enough), or when a declared `evidence:`
       hint resolves (`dep:` a direct dependency, `module:` a real app-module
       prefix, `host:` a collected HTTP boundary). The escape hatch
       `evidence: [manual: "reason"]` marks it corroborated-by-assertion (a
       non-empty reason is required). An unevidenced external — or a declared hint
       that does not resolve — is an error. This check is never skipped: v3 wires
       collection everywhere, so "nothing collected" means the external is genuinely
       unevidenced.
    3. **Context modules.** A context's `modules:` prefix must name at least one
       real module. Skipped, with a warning, when no module list is available.

  Everything read here is deterministic: the same declarations and collected inputs
  always produce the same ordered errors and warnings.
  """

  alias ArchLens.Collect.Externals
  alias ArchLens.System.ExternalEvidence

  @entry_point_uses Enum.uniq(ArchLens.Collect.EntryPoints.kinds() ++ [:cron, :channel])

  defstruct entry_point_kinds: MapSet.new(),
            entry_points_collected?: false,
            external_ids: MapSet.new(),
            external_targets: MapSet.new(),
            deps: MapSet.new(),
            known_modules: MapSet.new(),
            modules_known?: false

  @type t :: %__MODULE__{}

  @type declared :: %{
          actors: [map()],
          externals: [map()],
          contexts: [map()]
        }

  @doc "The known entry-point kinds an actor may declare in `uses:`."
  @spec entry_point_uses() :: [atom()]
  def entry_point_uses, do: @entry_point_uses

  @doc """
  Build a validation context from raw collected inputs.

  Recognised keys: `:entry_points`, `:external_systems` (the real
  `ArchLens.Collect.Externals` element shape — `%{id, vendor, evidence, …}`),
  `:known_modules`, and `:deps` (the host app's direct dependency names, used to
  resolve `evidence: [dep: …]` hints; defaults to
  `ArchLens.Collect.Externals.scanned_dep_names/0` when absent).
  """
  @spec context(map()) :: t()
  def context(inputs) when is_map(inputs) do
    entry_points = Map.get(inputs, :entry_points) || []
    externals = Map.get(inputs, :external_systems) || []
    known = Map.get(inputs, :known_modules) || []
    deps = Map.get(inputs, :deps) || Externals.scanned_dep_names()

    %__MODULE__{
      entry_points_collected?: entry_points != [],
      entry_point_kinds:
        entry_points |> Enum.map(&read(&1, :kind)) |> reject_nil() |> string_set(),
      external_ids:
        externals |> Enum.map(&collected_external_id/1) |> reject_nil() |> MapSet.new(),
      external_targets: externals |> Enum.flat_map(&collected_target_hosts/1) |> MapSet.new(),
      deps: MapSet.new(deps, &to_string/1),
      known_modules: MapSet.new(known, &to_string/1),
      modules_known?: known != []
    }
  end

  @doc """
  Validate `declared` (maps of actors/externals/contexts) against `ctx`.

  Returns `{:ok, warnings}` when every check passes or is skipped, or
  `{:error, errors}` with every failing check. Both lists are sorted and
  de-duplicated.
  """
  @spec validate(declared(), t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def validate(declared, %__MODULE__{} = ctx) do
    {errors, warnings} =
      {[], []}
      |> check_actors(Map.get(declared, :actors, []), ctx)
      |> check_externals(Map.get(declared, :externals, []), ctx)
      |> check_contexts(Map.get(declared, :contexts, []), ctx)

    case Enum.sort(Enum.uniq(errors)) do
      [] -> {:ok, Enum.sort(Enum.uniq(warnings))}
      errors -> {:error, errors}
    end
  end

  # --- rule (a): actor uses -----------------------------------------------------

  defp check_actors(acc, actors, ctx) do
    acc
    |> check_actor_vocabulary(actors)
    |> check_actor_entry_points(actors, ctx)
  end

  # (a1) Every `uses:` atom must name a known entry-point kind. Always enforced,
  # whether or not entry points were collected.
  defp check_actor_vocabulary(acc, actors) do
    Enum.reduce(actors, acc, fn actor, acc ->
      actor
      |> Map.get(:uses, [])
      |> Enum.reject(&(&1 in @entry_point_uses))
      |> Enum.reduce(acc, &unknown_use_error(actor, &1, &2))
    end)
  end

  defp unknown_use_error(actor, use, acc) do
    add_error(
      acc,
      "actor #{inspect(actor[:name])} declares uses: #{inspect(use)}, which is not a known " <>
        "entry-point kind (allowed: #{inspect(@entry_point_uses)})."
    )
  end

  # (a2) Every known kind an actor uses must have been collected. Skipped, with a
  # warning, when no entry points were collected.
  defp check_actor_entry_points(acc, actors, %{entry_points_collected?: false}) do
    if Enum.any?(actors, &uses_entry_point?/1) do
      add_warning(acc, "entry points not collected — skipped actor entry-point validation.")
    else
      acc
    end
  end

  defp check_actor_entry_points(acc, actors, ctx) do
    Enum.reduce(actors, acc, &check_actor(&1, &2, ctx))
  end

  defp uses_entry_point?(actor) do
    actor |> Map.get(:uses, []) |> Enum.any?(&(&1 in @entry_point_uses))
  end

  defp check_actor(actor, acc, ctx) do
    actor
    |> Map.get(:uses, [])
    |> Enum.filter(&(&1 in @entry_point_uses))
    |> Enum.reduce(acc, &check_actor_use(actor, &1, &2, ctx))
  end

  defp check_actor_use(actor, use, acc, ctx) do
    if MapSet.member?(ctx.entry_point_kinds, to_string(use)) do
      acc
    else
      add_error(
        acc,
        "actor #{inspect(actor[:name])} declares uses: #{inspect(use)} " <>
          "but no #{inspect(use)} entry point was collected."
      )
    end
  end

  # --- rule (b): externals ------------------------------------------------------

  defp check_externals(acc, externals, ctx) do
    resolve_ctx = resolve_context(ctx)
    Enum.reduce(externals, acc, &check_external(&1, &2, resolve_ctx))
  end

  defp check_external(external, acc, resolve_ctx) do
    case ExternalEvidence.resolve(external, resolve_ctx) do
      {:corroborated, _evidence} -> acc
      {:manual, _evidence} -> acc
      {:unevidenced, detail} -> add_error(acc, external_error(external, detail))
    end
  end

  defp resolve_context(ctx) do
    %{
      external_ids: ctx.external_ids,
      external_hosts: ctx.external_targets,
      deps: ctx.deps,
      known_modules: ctx.known_modules
    }
  end

  defp external_error(external, :no_evidence) do
    "#{external_ref(external)} matches no collected external system or HTTP boundary, " <>
      "and declares no evidence: hint. Add evidence: [dep: :some_dep], [module: \"Prefix\"], " <>
      "or [host: \"api.example.com\"], or the escape hatch [manual: \"reason\"]."
  end

  defp external_error(external, {:unresolved_hint, {:dep, dep}}) do
    "#{external_ref(external)} declares evidence: [dep: #{inspect(dep)}] but that is not a " <>
      "direct dependency. Name a real direct dep, or use evidence: [manual: \"reason\"]."
  end

  defp external_error(external, {:unresolved_hint, {:module, prefix}}) do
    "#{external_ref(external)} declares evidence: [module: #{inspect(prefix)}] but no app " <>
      "module has that prefix. Name a real module prefix, or use evidence: [manual: \"reason\"]."
  end

  defp external_error(external, {:unresolved_hint, {:host, host}}) do
    "#{external_ref(external)} declares evidence: [host: #{inspect(host)}] but no collected " <>
      "HTTP boundary uses that host. Name a boundary host, or use evidence: [manual: \"reason\"]."
  end

  defp external_error(external, reason)
       when reason in [:empty_manual_reason, :manual_needs_reason] do
    "#{external_ref(external)} declares evidence: [manual: …] without a reason. " <>
      "Provide a non-empty reason: evidence: [manual: \"why this external is real\"]."
  end

  defp external_error(external, {:unknown_hint, keys}) do
    "#{external_ref(external)} declares an unknown evidence: hint #{inspect(keys)}. " <>
      "Use dep:, module:, host:, or manual:."
  end

  defp external_ref(external) do
    "external #{inspect(external[:name])} (via #{inspect(external[:via])}, " <>
      "target #{inspect(external[:target])})"
  end

  # The stable id a collected external system carries, mirroring
  # ArchLens.System.ExternalMerge and ArchLens.Collect.Externals: an explicit `:id`,
  # else `external:<slug(vendor | label | name)>`. `nil` when nothing identifies it.
  defp collected_external_id(entry) do
    case read(entry, :id) do
      nil ->
        case read(entry, :vendor) || read(entry, :label) || read(entry, :name) do
          nil -> nil
          base -> "external:" <> slug(base)
        end

      id ->
        to_string(id)
    end
  end

  # Target hosts a collected external system was actually seen talking to: the value
  # of each `http_boundary` evidence entry, canonicalised to a host.
  defp collected_target_hosts(entry) do
    entry
    |> read(:evidence)
    |> List.wrap()
    |> Enum.filter(fn ev -> is_map(ev) and read(ev, :type) == "http_boundary" end)
    |> Enum.map(&read(&1, :value))
    |> reject_nil()
    |> Enum.map(&target_host/1)
    |> Enum.reject(&(&1 == ""))
  end

  # --- rule (c): context modules ------------------------------------------------

  defp check_contexts(acc, contexts, ctx) do
    with_modules = Enum.filter(contexts, &present?(&1[:modules]))

    cond do
      with_modules == [] ->
        acc

      not ctx.modules_known? ->
        add_warning(acc, "module list unavailable — skipped context module-prefix validation.")

      true ->
        Enum.reduce(with_modules, acc, &check_context(&1, &2, ctx))
    end
  end

  defp check_context(context, acc, ctx) do
    if module_prefix_matches?(context[:modules], ctx.known_modules) do
      acc
    else
      add_error(
        acc,
        "context #{inspect(context[:name])} declares modules: #{inspect(context[:modules])} " <>
          "but no module with that prefix exists."
      )
    end
  end

  defp module_prefix_matches?(prefix, known_modules) do
    Enum.any?(known_modules, fn module ->
      module == prefix or String.starts_with?(module, prefix <> ".")
    end)
  end

  # --- helpers ------------------------------------------------------------------

  defp add_error({errors, warnings}, message), do: {[message | errors], warnings}
  defp add_warning({errors, warnings}, message), do: {errors, [message | warnings]}

  defp read(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, to_string(key))
  end

  defp read(_entry, _key), do: nil

  defp reject_nil(list), do: Enum.reject(list, &is_nil/1)

  defp string_set(values), do: MapSet.new(values, &to_string/1)

  # Mirrors ArchLens.Collect.Externals / ExternalMerge slugging so a declared
  # external's id lines up with the collected external system's id.
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

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
