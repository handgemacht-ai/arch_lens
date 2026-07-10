defmodule ArchLens.System.Validate do
  @moduledoc """
  Reconciles a declared architecture against what the generator collected — the
  honesty gate for `ArchLens.System`, one rung above `ArchLens.Generator.Retention`.

  Three checks, run together so *all* failures are reported at once:

    1. **Actor entry points.** An actor that `uses:` an entry-point surface
       (`:api`, `:mcp`, `:browser`, `:webhook`) requires a matching collected entry
       point. Skipped, with a recorded warning, when no entry points were collected.
    2. **HTTP externals.** A declared `external via: :http` must match a collected
       external system's target or a dependency vendor. Skipped, with a warning,
       when no external systems were collected.
    3. **Context modules.** A context's `modules:` prefix must name at least one
       real module. Skipped, with a warning, when no module list is available.

  Everything read here is deterministic: the same declarations and collected inputs
  always produce the same ordered errors and warnings.
  """

  @entry_point_uses [:api, :browser, :mcp, :webhook]

  defstruct entry_point_kinds: MapSet.new(),
            entry_points_collected?: false,
            external_targets: MapSet.new(),
            externals_collected?: false,
            vendors: MapSet.new(),
            known_modules: MapSet.new(),
            modules_known?: false

  @type t :: %__MODULE__{}

  @type declared :: %{
          actors: [map()],
          externals: [map()],
          contexts: [map()]
        }

  @doc "The entry-point surfaces that are validated against collected entry points."
  @spec entry_point_uses() :: [atom()]
  def entry_point_uses, do: @entry_point_uses

  @doc """
  Build a validation context from raw collected inputs.

  Recognised keys: `:entry_points`, `:external_systems`, `:vendors`,
  `:known_modules`.
  """
  @spec context(map()) :: t()
  def context(inputs) when is_map(inputs) do
    entry_points = Map.get(inputs, :entry_points) || []
    externals = Map.get(inputs, :external_systems) || []
    vendors = Map.get(inputs, :vendors) || []
    known = Map.get(inputs, :known_modules) || []

    %__MODULE__{
      entry_points_collected?: entry_points != [],
      entry_point_kinds:
        entry_points |> Enum.map(&read(&1, :kind)) |> reject_nil() |> string_set(),
      externals_collected?: externals != [],
      external_targets:
        externals
        |> Enum.map(&read(&1, :target))
        |> reject_nil()
        |> Enum.map(&normalize_target/1)
        |> MapSet.new(),
      vendors: string_set(vendors),
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

  # --- rule (a): actor entry points ---------------------------------------------

  defp check_actors(acc, actors, %{entry_points_collected?: false}) do
    if Enum.any?(actors, &uses_entry_point?/1) do
      add_warning(acc, "entry points not collected — skipped actor entry-point validation.")
    else
      acc
    end
  end

  defp check_actors(acc, actors, ctx) do
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
          "matches no collected external system or dependency vendor."
      )
    end
  end

  defp external_matched?(external, ctx) do
    target = normalize_target(external[:target])

    MapSet.member?(ctx.external_targets, target) or
      MapSet.member?(ctx.vendors, to_string(external[:name]))
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

  defp normalize_target(nil), do: ""
  defp normalize_target(target), do: target |> to_string() |> String.trim_trailing("/")

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
