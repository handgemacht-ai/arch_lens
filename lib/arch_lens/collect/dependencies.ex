defmodule ArchLens.Collect.Dependencies do
  @moduledoc """
  Collects raw cross-module call references — the source of the G1 cross-context
  dependency edges.

  A private OTP `:xref` call graph is built over the app's *own* compiled BEAMs
  (`Application.app_dir(app, "ebin")`), the line-annotated call edges are queried,
  and the result is folded into a deterministic, sorted list of raw references

      [%{from_module, to_module, call_sites: [%{file, line}]}]

  where `file` is the calling module's repo-relativised source and `line` is
  best-effort (a call site with no resolvable line carries only `file`).

  ## Environment independence

  Both endpoints of every edge are intersected with the caller-supplied `:modules`
  set — the lib-only production set from `ArchLens.Generator.Scan.app_modules/1`.
  Under `MIX_ENV=test` the app's ebin also holds `test/support` BEAMs; filtering
  both ends to the lib set drops them, so the reference set is byte-identical across
  environments. Dependency BEAMs live in their own ebin dirs and are never added, so
  they cannot appear either. Only direct module-to-module references are recorded (an
  `A -> dep -> B` path is not an `A -> B` edge), and a module referencing itself is
  not a cross-module reference and is dropped.

  ## Availability

  `:xref` ships in the OTP `:tools` application. When `:tools` is present on disk but
  not yet on the code path, its ebin is added before use. When the app is in scope but
  `:xref` genuinely cannot be loaded, `collect/1` raises rather than emitting an empty
  section — an empty result is only honest when there is no app or no module set.
  """

  alias ArchLens.Generator.Paths

  # :xref is loaded at runtime from the OTP :tools application (see ensure_xref!/0),
  # which Mix does not put on the compile-time code path.
  @compile {:no_warn_undefined, :xref}

  @doc """
  Raw cross-module call references for the app named by `:app`, with both endpoints
  restricted to the `:modules` set.

  Returns `[]` when either `:app` or `:modules` is absent — the same skip semantics
  the generation gates use. Otherwise runs `:xref` over the app's own ebin and returns
  the deterministic, module-name-sorted reference list.
  """
  @spec collect(keyword()) :: [map()]
  def collect(opts \\ []) do
    do_collect(Keyword.get(opts, :app), Keyword.get(opts, :modules, []))
  end

  defp do_collect(nil, _modules), do: []
  defp do_collect(_app, []), do: []

  defp do_collect(app, modules) do
    ensure_xref!()
    module_set = MapSet.new(modules)

    app
    |> reference_edges()
    |> aggregate(module_set)
  end

  # The line-annotated call edges from a private, uniquely-named :xref server over
  # the app's own compiled BEAMs. Each edge is `{{FromMFA, ToMFA}, Lines}` where
  # `Lines` is a list of source lines (0 for a call with no line annotation).
  defp reference_edges(app) do
    _ = Application.load(app)
    ebin = Application.app_dir(app, "ebin")
    server = :"arch_lens_xref_#{System.unique_integer([:positive])}"

    {:ok, _pid} = :xref.start(server)

    try do
      :xref.set_default(server, verbose: false, warnings: false)
      {:ok, _modules} = :xref.add_directory(server, String.to_charlist(ebin))
      {:ok, edges} = :xref.q(server, ~c"(Lin) E")
      edges
    after
      :xref.stop(server)
    end
  end

  defp aggregate(edges, module_set) do
    edges
    |> Enum.reduce(%{}, &fold_edge(&1, &2, module_set))
    |> Enum.map(fn {{from_module, to_module}, lines} -> ref(from_module, to_module, lines) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn %{from_module: from, to_module: to} ->
      {Atom.to_string(from), Atom.to_string(to)}
    end)
  end

  defp fold_edge({{{from_module, _, _}, {to_module, _, _}}, lines}, acc, module_set) do
    if cross_module_reference?(from_module, to_module, module_set) do
      Map.update(
        acc,
        {from_module, to_module},
        present_lines(lines),
        &MapSet.union(&1, present_lines(lines))
      )
    else
      acc
    end
  end

  defp cross_module_reference?(from_module, to_module, module_set) do
    from_module != to_module and
      MapSet.member?(module_set, from_module) and
      MapSet.member?(module_set, to_module)
  end

  defp present_lines(lines) do
    lines |> Enum.filter(&(&1 > 0)) |> MapSet.new()
  end

  # A module pair's reference: the calling module's relativised source `file`, and one
  # call site per resolved line (or a single file-only site when no line resolved). A
  # module with no resolvable source cannot be relativised and is dropped (a lib module
  # always carries a source, so this only guards synthetic modules).
  defp ref(from_module, to_module, lines) do
    case module_file(from_module) do
      nil ->
        nil

      file ->
        %{from_module: from_module, to_module: to_module, call_sites: call_sites(file, lines)}
    end
  end

  defp call_sites(file, lines) do
    case Enum.sort(lines) do
      [] -> [%{file: file}]
      sorted -> Enum.map(sorted, &%{file: file, line: &1})
    end
  end

  defp module_file(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         source when is_list(source) or is_binary(source) <-
           module.__info__(:compile)[:source] do
      source |> to_string() |> Paths.relativize()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # :xref lives in the OTP :tools application. Mix does not put :tools on the code
  # path, so add its ebin (resolved under the OTP root) when :xref is not yet loadable.
  defp ensure_xref! do
    unless Code.ensure_loaded?(:xref) do
      :code.root_dir()
      |> List.to_string()
      |> Path.join("lib/tools-*/ebin")
      |> Path.wildcard()
      |> Enum.each(&Code.append_path/1)
    end

    unless Code.ensure_loaded?(:xref) do
      raise "ArchLens.Collect.Dependencies needs OTP :xref (the :tools application), " <>
              "which is not available. Install the OTP :tools application to collect " <>
              "cross-context dependency edges."
    end
  end
end
