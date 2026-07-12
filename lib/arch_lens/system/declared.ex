defmodule ArchLens.System.Declared do
  @moduledoc """
  Turns an `ArchLens.System` module into the validated `declared_architecture`
  value the generator's `Scope`/`Model` render from.

  `build/1` reads the declared entities into normalized, `source: "declared"` maps.
  `resolve!/2` builds them, validates them against the collected inputs
  (`ArchLens.System.Validate`), and either returns the structured value — actors,
  externals, contexts, plus any skipped-validation `warnings` — or raises
  `ArchLens.System.ValidationError` listing every failing check.

  When the caller does not supply `:known_modules`, they are derived
  deterministically from the app's production (`lib/`) modules and the
  already-collected scope so context module prefixes can be checked without a
  database — and so validation does not pass under `:test` (where `test/support`
  modules leak into the app) yet fail under `:dev`.
  """

  alias ArchLens.Edge
  alias ArchLens.Generator.Scan
  alias ArchLens.System.{Info, Validate, ValidationError}

  @type scope_value :: %{
          actors: [map()],
          externals: [map()],
          contexts: [map()],
          flows: [map()],
          identity: map() | nil,
          warnings: [String.t()]
        }

  @doc """
  Normalized, `source: "declared"` maps for a System module (no validation).

  Flows and the town identity are carried raw — the generator resolves and gates
  them (`ArchLens.Generator.Flows`, `ArchLens.Town`), not this module.
  """
  @spec build(module()) :: %{
          actors: [map()],
          externals: [map()],
          contexts: [map()],
          flows: [map()],
          identity: map() | nil
        }
  def build(system) do
    %{
      actors: system |> Info.actors() |> Enum.map(&actor_map/1),
      externals: system |> Info.externals() |> Enum.map(&external_map/1),
      contexts: system |> Info.contexts() |> Enum.map(&context_map/1),
      flows: system |> Info.flows() |> Enum.map(&flow_map/1),
      identity: system |> Info.identity() |> identity_map()
    }
  end

  @doc """
  Build and validate the declared architecture for `system`.

  `inputs` carries the collected context: `:entry_points`, `:external_systems`,
  optionally `:app`, `:resources`, `:oban_workers`, `:edges` (to derive known
  modules), and the `:known_modules` override.

  Returns the structured scope value, or raises `ArchLens.System.ValidationError`.
  """
  @spec resolve!(module(), map()) :: scope_value()
  def resolve!(system, inputs \\ %{}) do
    declared = build(system)
    ctx = Validate.context(collection_inputs(inputs))

    case Validate.validate(declared, ctx) do
      {:ok, warnings} -> Map.put(declared, :warnings, warnings)
      {:error, errors} -> raise ValidationError, errors: errors
    end
  end

  defp actor_map(actor) do
    %{name: actor.name, uses: actor.uses, does: actor.does, source: "declared"}
  end

  defp external_map(external) do
    %{
      name: external.name,
      via: external.via,
      target: external.target,
      does: external.does,
      evidence_hint: external.evidence,
      source: "declared"
    }
  end

  defp context_map(context) do
    %{name: context.name, does: context.does, modules: context.modules, source: "declared"}
  end

  defp flow_map(flow) do
    %{
      name: flow.name,
      does: flow.does,
      steps: Enum.map(flow.steps, &step_map/1),
      source: "declared"
    }
  end

  defp step_map(step) do
    %{kind: step.kind, ref: step.ref, does: step.does, unverified: step.unverified}
  end

  defp identity_map(nil), do: nil

  defp identity_map(identity) do
    %{id: identity.id, name: identity.name, aliases: identity.aliases, source: "declared"}
  end

  defp collection_inputs(inputs) do
    %{
      entry_points: Map.get(inputs, :entry_points, []),
      external_systems: Map.get(inputs, :external_systems, []),
      known_modules: Map.get(inputs, :known_modules) || derive_known_modules(inputs)
    }
  end

  defp derive_known_modules(inputs) do
    app_modules = inputs |> Map.get(:app) |> Scan.app_modules()
    scope_modules = scope_modules(inputs)

    (app_modules ++ scope_modules)
    |> Enum.map(&Edge.module_name/1)
    |> Enum.uniq()
  end

  defp scope_modules(inputs) do
    resources = Map.get(inputs, :resources, [])
    workers = Map.get(inputs, :oban_workers, [])
    edge_modules = inputs |> Map.get(:edges, []) |> Enum.flat_map(&edge_modules/1)

    Enum.filter(resources ++ workers ++ edge_modules, &is_atom/1)
  end

  defp edge_modules(%Edge{builder: builder, target: target}) do
    Enum.filter([builder_module(builder), target], &is_atom/1)
  end

  defp builder_module({module, _fun, _arity}), do: module
  defp builder_module({module, _name}), do: module
  defp builder_module(module) when is_atom(module), do: module
  defp builder_module(_), do: nil
end
