defmodule ArchLens.System.Validate do
  @moduledoc """
  Reconciles a declared architecture against what the generator collected — the
  honesty gate for `ArchLens.System`, one rung above `ArchLens.Generator.Retention`.

  Three checks, run together so *all* failures are reported at once:

    1. **Actor `uses:`.** Two things are enforced. First, *vocabulary*: every atom
       an actor `uses:` must name a known entry-point kind — the canonical list the
       generator emits, `ArchLens.Collect.EntryPoints.kinds/0`
       (`:browser`, `:api`, `:webhook`, `:oauth`, `:mcp`, `:other`), widened here
       with `:cron` and `:channel` for the cron and channel entry-point surfaces.
       An unknown atom always fails, whether or not entry points were collected.
       Second, a
       *collected cross-check*: when entry points were collected, each known kind an
       actor uses must also appear among them. Only the cross-check is skipped, with
       a recorded warning, when no entry points were collected — the vocabulary
       check still runs.
    2. **HTTP externals.** A declared `external via: :http` must corroborate against
       something the collector actually found — matched the same way
       `ArchLens.System.ExternalMerge` matches: the declared external's stable id
       (`external:<slug(name)>`) equals a collected external system's id/vendor slug,
       *or* the declared target's host equals a host in a collected system's HTTP
       boundary evidence. A bare name collision with an arbitrary dependency app is
       **not** enough. Skipped, with a warning, when no external systems were
       collected.
    3. **Context modules.** A context's `modules:` prefix must name at least one
       real module. Skipped, with a warning, when no module list is available.

  Everything read here is deterministic: the same declarations and collected inputs
  always produce the same ordered errors and warnings.
  """

  @entry_point_uses Enum.uniq(ArchLens.Collect.EntryPoints.kinds() ++ [:cron, :channel])

  defstruct entry_point_kinds: MapSet.new(),
            entry_points_collected?: false,
            external_ids: MapSet.new(),
            external_targets: MapSet.new(),
            externals_collected?: false,
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
  `:known_modules`.
  """
  @spec context(map()) :: t()
  def context(inputs) when is_map(inputs) do
    entry_points = Map.get(inputs, :entry_points) || []
    externals = Map.get(inputs, :external_systems) || []
    known = Map.get(inputs, :known_modules) || []

    %__MODULE__{
      entry_points_collected?: entry_points != [],
      entry_point_kinds:
        entry_points |> Enum.map(&read(&1, :kind)) |> reject_nil() |> string_set(),
      externals_collected?: externals != [],
      external_ids:
        externals |> Enum.map(&collected_external_id/1) |> reject_nil() |> MapSet.new(),
      external_targets: externals |> Enum.flat_map(&collected_target_hosts/1) |> MapSet.new(),
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

  # --- rule (b): HTTP externals -------------------------------------------------

  defp check_externals(acc, externals, %{externals_collected?: false}) do
    if Enum.any?(externals, &(&1[:via] == :http)) do
      add_warning(acc, "external systems not collected — skipped external validation.")
    else
      acc
    end
  end

  defp check_externals(acc, externals, ctx) do
    externals
    |> Enum.filter(&(&1[:via] == :http))
    |> Enum.reduce(acc, &check_external(&1, &2, ctx))
  end

  defp check_external(external, acc, ctx) do
    if external_matched?(external, ctx) do
      acc
    else
      add_error(
        acc,
        "external #{inspect(external[:name])} (via :http, target #{inspect(external[:target])}) " <>
          "matches no collected external system or HTTP boundary."
      )
    end
  end

  # Matched the same way ArchLens.System.ExternalMerge collapses declared and
  # collected externals: by the shared stable id (`external:<slug(name/vendor)>`),
  # or by the declared target host appearing in a collected system's HTTP boundary
  # evidence. Deliberately no raw dependency-name match — a name that merely
  # collides with some app in the OTP closure must not corroborate egress.
  defp external_matched?(external, ctx) do
    id = "external:" <> slug(external[:name])

    MapSet.member?(ctx.external_ids, id) or
      MapSet.member?(ctx.external_targets, target_host(external[:target]))
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
