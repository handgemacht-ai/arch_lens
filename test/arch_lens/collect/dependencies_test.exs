defmodule ArchLens.Collect.DependenciesTest do
  # async: false — starts a private :xref server over the whole arch_lens ebin.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Dependencies

  # Self-owned reference edges: ContextEdges.build calls Namespace.attribute (twice,
  # for the from/to endpoints) and Dependencies.module_file calls Paths.relativize.
  # Anchoring on this slice's own call sites keeps the assertions stable regardless of
  # how other slices refactor unrelated modules.
  @context_edges ArchLens.Generator.ContextEdges
  @namespace ArchLens.Generator.Namespace
  @dependencies ArchLens.Collect.Dependencies
  @paths ArchLens.Generator.Paths

  describe "skip semantics (empty is honest)" do
    test "no app and no modules yields nothing" do
      assert Dependencies.collect([]) == []
    end

    test "an app with an empty module set yields nothing" do
      assert Dependencies.collect(app: :arch_lens, modules: []) == []
    end

    test "a module set with no app yields nothing" do
      assert Dependencies.collect(modules: [@context_edges, @namespace]) == []
    end
  end

  describe "collect/1 over compiled BEAMs" do
    test "a real cross-module reference is collected with the caller's source and lines" do
      assert [ref] =
               Dependencies.collect(app: :arch_lens, modules: [@context_edges, @namespace])

      assert ref.from_module == @context_edges
      assert ref.to_module == @namespace

      lines = Enum.map(ref.call_sites, & &1.line)
      files = ref.call_sites |> Enum.map(& &1.file) |> Enum.uniq()

      assert files == ["lib/arch_lens/generator/context_edges.ex"]
      assert Enum.all?(lines, &(is_integer(&1) and &1 > 0))
      assert lines == Enum.sort(lines)
      assert lines == Enum.uniq(lines)
    end

    test "both endpoints are intersected with the module set (a missing callee drops the edge)" do
      # ContextEdges references Namespace, but with Namespace absent from the set the
      # edge is dropped — proving the callee-side intersection (the env-independence
      # mechanism: the caller passes the lib-only set, both ends must be in it).
      assert Dependencies.collect(app: :arch_lens, modules: [@context_edges]) == []
    end

    test "a module referencing nothing else in the set yields nothing (no self-edges)" do
      assert Dependencies.collect(app: :arch_lens, modules: [@namespace]) == []
    end

    test "the paths collector's own call into Generator.Paths is a real edge" do
      assert [ref] = Dependencies.collect(app: :arch_lens, modules: [@dependencies, @paths])
      assert ref.from_module == @dependencies
      assert ref.to_module == @paths
      assert [%{file: "lib/arch_lens/collect/dependencies.ex", line: line}] = ref.call_sites
      assert line > 0
    end

    test "collection is deterministic across runs" do
      opts = [app: :arch_lens, modules: [@context_edges, @namespace, @dependencies, @paths]]
      assert Dependencies.collect(opts) == Dependencies.collect(opts)
    end

    test "no collected reference is a module self-edge" do
      refs =
        Dependencies.collect(
          app: :arch_lens,
          modules: [@context_edges, @namespace, @dependencies, @paths]
        )

      refute Enum.any?(refs, &(&1.from_module == &1.to_module))
    end
  end
end
