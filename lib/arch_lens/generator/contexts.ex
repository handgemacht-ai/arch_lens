defmodule ArchLens.Generator.Contexts do
  @moduledoc """
  Resolves the app's bounded contexts from in-place annotations, and holds the two
  generation-time gates that keep those annotations honest.

  A context is discovered three ways, in priority order:

    1. an `Ash.Domain` carrying the `ArchLens.Domain` extension (`origin: "domain"`,
       with resource membership from `Ash.Domain.Info.resources/1`),
    2. a plain context module carrying `use ArchLens.Context` (with or without a
       directory of children — a flat single-file context surfaces too), or merely
       a `@moduledoc` on the root of a top-level directory (`origin: "context_module"`),
    3. a central `context` entity in an `ArchLens.System` block
       (`origin: "central_declared"`) — the deprecated path.

  `resolve/1` folds these into the deterministic, `provenance: "declared"` context
  list the model renders, preferring an in-place annotation over a duplicate central
  declaration and emitting deprecation/duplicate warnings for the central path.

  ## Style gate

  `style_gate/1` fails when a top-level directory under the app namespace
  (`lib/<app>/<dir>/`, derived from the compiled module list) has no corresponding
  root module `<App>.<Dir>`. Directories named in `ignore_namespaces` are skipped.

  ## Annotation gate

  `annotation_gate/1` fails when a discovered `Ash.Domain` or a root context module
  carries no resolvable description (`does` or `@moduledoc`) and is not
  `exclude: true`. This is the gate that catches a real gap — a domain that exists
  but nobody described.

  Both gates skip cleanly (return `:ok`) when the app namespace or module list is
  unavailable, so the generator stays usable with an explicit, DB-free scope.
  """

  alias ArchLens.Context.Info, as: ContextInfo
  alias ArchLens.Domain
  alias ArchLens.Edge
  alias ArchLens.Generator.Namespace
  alias ArchLens.Generator.Scope
  alias Ash.Domain.Info, as: DomainInfo

  @type resolved :: %{contexts: [map()]}

  @doc """
  The resolved, deterministic context list for `scope`, sorted by name.

  Each context carries an `id` (`"context:<name>"`, the stable id edges, flow steps,
  and diffs join on) and, for an in-place context, the annotated `module`
  (`ArchLens.Generator.Namespace` attributes modules to contexts through it). A
  deprecated central declaration has no resolvable module, so it carries no `module`.

  Excluded and undescribed candidates are dropped; central declarations that
  collide with an in-place annotation are dropped with a warning; any central
  declarations at all emit a deprecation warning (to standard error, so the
  rendered artifacts stay byte-stable).
  """
  @spec resolve(Scope.t()) :: resolved()
  def resolve(%Scope{} = scope) do
    in_place = domain_contexts(scope) ++ module_contexts(scope)
    central = reconcile_central(central_contexts(scope), in_place)

    contexts =
      (in_place ++ central)
      |> dedup_by_name()
      |> Enum.sort_by(&to_string(&1.name))

    %{contexts: contexts}
  end

  @doc """
  `:ok`, or `{:error, {:missing_root_modules, names}}` when a top-level directory
  under the app namespace has no root module. `names` are sorted module-name strings.
  """
  @spec style_gate(Scope.t()) :: :ok | {:error, {:missing_root_modules, [String.t()]}}
  def style_gate(%Scope{} = scope) do
    case module_set(scope) do
      nil ->
        :ok

      set ->
        missing =
          scope
          |> Namespace.folder_namespaces()
          |> Enum.map(&Namespace.root_module(scope, &1))
          |> Enum.reject(&MapSet.member?(set, &1))
          |> Enum.map(&Edge.module_name/1)
          |> Enum.sort()

        gate_result(missing, :missing_root_modules)
    end
  end

  @doc """
  `:ok`, or `{:error, {:undescribed_contexts, names}}` when a discovered domain or
  root context module has no resolvable description and is not excluded. `names` are
  sorted module-name strings.
  """
  @spec annotation_gate(Scope.t()) :: :ok | {:error, {:undescribed_contexts, [String.t()]}}
  def annotation_gate(%Scope{} = scope) do
    domain_offenders = Enum.reject(scope.domains, &domain_covered?/1)
    module_offenders = Enum.reject(context_modules(scope), &module_covered?/1)

    offenders =
      (domain_offenders ++ module_offenders)
      |> Enum.map(&Edge.module_name/1)
      |> Enum.uniq()
      |> Enum.sort()

    gate_result(offenders, :undescribed_contexts)
  end

  # --- domain / module contexts -------------------------------------------

  defp domain_contexts(%Scope{domains: domains}) do
    domains
    |> Enum.reject(&Domain.excluded?/1)
    |> Enum.filter(&Domain.described?/1)
    |> Enum.map(&domain_context/1)
  end

  defp domain_context(domain) do
    {does, source} = Domain.does(domain)
    name = Domain.name(domain)

    %{
      id: context_id(name),
      name: name,
      module: domain,
      does: does,
      origin: :domain,
      provenance: :declared,
      does_source: source,
      resources: domain |> DomainInfo.resources() |> Enum.map(&Edge.module_name/1) |> Enum.sort()
    }
  end

  defp module_contexts(scope) do
    scope
    |> context_modules()
    |> Enum.reject(&ContextInfo.excluded?/1)
    |> Enum.filter(&ContextInfo.described?/1)
    |> Enum.map(&module_context/1)
  end

  defp module_context(module) do
    {does, source} = ContextInfo.does(module)
    name = ContextInfo.name(module)

    %{
      id: context_id(name),
      name: name,
      module: module,
      does: does,
      origin: :context_module,
      provenance: :declared,
      does_source: source
    }
  end

  # --- central (deprecated) contexts --------------------------------------

  defp central_contexts(%Scope{declared_architecture: %{contexts: contexts}})
       when is_list(contexts) do
    Enum.map(contexts, &central_context/1)
  end

  defp central_contexts(_scope), do: []

  defp central_context(context) do
    name = read(context, :name)

    %{
      id: context_id(name),
      name: name,
      does: read(context, :does),
      origin: :central_declared,
      provenance: :declared,
      does_source: :annotation
    }
    |> put_present(:modules, read(context, :modules))
  end

  defp reconcile_central([], _in_place), do: []

  defp reconcile_central(central, in_place) do
    warn_central_deprecated(central)
    in_place_names = MapSet.new(in_place, & &1.name)

    Enum.reject(central, fn context ->
      if MapSet.member?(in_place_names, context.name) do
        warn_central_duplicate(context.name)
        true
      end
    end)
  end

  defp warn_central_deprecated(central) do
    names = central |> Enum.map(&inspect(&1.name)) |> Enum.join(", ")

    IO.warn(
      "ArchLens.System `context` declarations are deprecated (#{names}). Annotate the " <>
        "domain (ArchLens.Domain) or root module (ArchLens.Context) in place instead.",
      []
    )
  end

  defp warn_central_duplicate(name) do
    IO.warn(
      "context #{inspect(name)} is both declared centrally in ArchLens.System and annotated " <>
        "in place; preferring the in-place annotation.",
      []
    )
  end

  # --- gate coverage ------------------------------------------------------

  defp domain_covered?(domain), do: Domain.excluded?(domain) or Domain.described?(domain)

  defp module_covered?(module),
    do: ContextInfo.excluded?(module) or ContextInfo.described?(module)

  # --- namespace / module analysis ----------------------------------------

  # Context modules to resolve and gate: the root modules of non-ignored folder
  # namespaces, unioned with any module carrying a `use ArchLens.Context`
  # annotation (a flat single-file context has no folder namespace, so the
  # annotation is what includes it), minus the Ash domains and resources (those
  # are gated as domains or via privacy, not as plain context modules).
  defp context_modules(scope) do
    case module_set(scope) do
      nil ->
        []

      set ->
        domain_set = MapSet.new(scope.domains)

        (folder_root_modules(scope) ++ annotated_modules(scope))
        |> Enum.filter(&MapSet.member?(set, &1))
        |> Enum.reject(&MapSet.member?(domain_set, &1))
        |> Enum.reject(&Spark.Dsl.is?(&1, Ash.Domain))
        |> Enum.reject(&Spark.Dsl.is?(&1, Ash.Resource))
        |> Enum.uniq()
        |> Enum.sort_by(&Edge.module_name/1)
    end
  end

  defp folder_root_modules(scope) do
    scope
    |> Namespace.folder_namespaces()
    |> Enum.map(&Namespace.root_module(scope, &1))
  end

  # Modules under the app namespace carrying a `use ArchLens.Context` annotation.
  # Directory shape decides inclusion for the unannotated case; the annotation
  # decides it here, so a flat single-file context surfaces while an unannotated
  # single-file module stays invisible and ungated.
  defp annotated_modules(%Scope{modules: modules}) do
    Enum.filter(modules, &ContextInfo.annotated?/1)
  end

  # A `MapSet` of the app's modules, or `nil` when the namespace or module list is
  # unavailable (both gates skip in that case).
  defp module_set(%Scope{app_namespace: nil}), do: nil
  defp module_set(%Scope{modules: []}), do: nil
  defp module_set(%Scope{modules: modules}), do: MapSet.new(modules)

  # --- helpers ------------------------------------------------------------

  defp gate_result([], _reason), do: :ok
  defp gate_result(names, reason), do: {:error, {reason, names}}

  defp dedup_by_name(contexts) do
    {kept, _seen} =
      Enum.reduce(contexts, {[], MapSet.new()}, fn context, {kept, seen} ->
        if MapSet.member?(seen, context.name) do
          {kept, seen}
        else
          {[context | kept], MapSet.put(seen, context.name)}
        end
      end)

    Enum.reverse(kept)
  end

  defp context_id(name), do: "context:" <> to_string(name)

  defp read(context, key), do: Map.get(context, key) || Map.get(context, to_string(key))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
