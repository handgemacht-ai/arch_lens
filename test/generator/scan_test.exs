defmodule ArchLens.Generator.ScanTest do
  # The lib-only production filter that keeps MIX_ENV=test's extra elixirc_paths
  # (test/support) out of architecture discovery, the gates, and the artifact — so a
  # generated artifact is byte-identical whether it is produced under :dev or :test.
  #
  # async: false — compiles on-disk fixture modules and reads the shared :arch_lens
  # application module list.
  use ExUnit.Case, async: false

  alias ArchLens.Generator.{Architecture, Contexts, Scan, Scope}

  describe "app_modules/1 — lib-only production scan of a real application" do
    test "keeps lib/ modules and drops test/support modules of :arch_lens" do
      modules = Scan.app_modules(:arch_lens)

      # Real production modules survive.
      assert ArchLens.Generator.Scan in modules
      assert ArchLens.Generator.Contexts in modules

      # test/support fixtures (compiled into :arch_lens under MIX_ENV=test) are gone.
      refute ArchLens.CtxFixtures.Blog in modules
      refute ArchLens.TestSupport.UndeclaredResource in modules
      refute ArchLens.LibOnlyLeakFixture in modules
      refute ArchLens.LibOnlyLeakFixture.Entry in modules

      # Every surviving module's compiled source lives under the project's lib/.
      lib_root = Path.expand("lib", File.cwd!())

      assert Enum.all?(modules, fn m ->
               String.starts_with?(to_string(m.__info__(:compile)[:source]), lib_root <> "/")
             end)
    end

    test "an undeclared Ash resource defined in test/support does not leak into the inventory" do
      # ArchLens.TestSupport.UndeclaredResource is a real, extension-carrying Ash
      # resource compiled under test/support. It is present in the raw module list,
      # but the lib-only scan must keep it out of the resource inventory (otherwise
      # the privacy gate would trip under :test but not :dev).
      assert ArchLens.TestSupport.UndeclaredResource in raw_app_modules(:arch_lens)
      refute ArchLens.TestSupport.UndeclaredResource in Scan.ash_resources(:arch_lens)
    end
  end

  describe "a test-support context-shaped module never surfaces (the ParityCorpus shape)" do
    test "present in the raw scan, it is filtered out of the lib-only scan and its contexts" do
      raw = raw_app_modules(:arch_lens)
      assert ArchLens.LibOnlyLeakFixture in raw

      raw_names = context_names(scope_for(raw))
      lib_names = context_names(scope_for(Scan.app_modules(:arch_lens)))

      # Unfiltered, the test-support fixture surfaces as a bounded context; with the
      # lib-only filter it is gone. This is exactly the environment-dependent drift
      # the filter removes.
      assert :lib_only_leak_fixture in raw_names
      refute :lib_only_leak_fixture in lib_names
    end
  end

  describe "artifact identity across :dev and :test for a fixture host app" do
    @tag :tmp_dir
    test "same artifact bytes with and without the test-support leak", %{tmp_dir: tmp} do
      # A self-contained on-disk fixture host app with two genuinely distinct source
      # roots, so the lib-only filter can tell production from test-support by path:
      #   lib/blog.ex            -> …Blog (a flat, annotated context)   [production]
      #   test/support/corpus.ex -> …Corpus (annotated context) + …Corpus.Entry
      #                             [test-support — the ParityCorpus shape: a directory
      #                             root with a child]
      #
      # Corpus is described via an in-place annotation rather than a @moduledoc
      # because Code.fetch_docs/1 (the moduledoc fallback) needs an on-disk beam docs
      # chunk, which Code.compile_file does not emit; the @moduledoc-shaped leak is
      # covered separately against the real :arch_lens app (LibOnlyLeakFixture).
      lib_dir = Path.join(tmp, "lib")
      support_dir = Path.join(tmp, "test/support")
      File.mkdir_p!(lib_dir)
      File.mkdir_p!(support_dir)

      compile(Path.join(lib_dir, "blog.ex"), """
      defmodule ArchLens.ScanTmpFixture.Blog do
        @moduledoc false
        use ArchLens.Context, does: "publishes posts and manages drafts"
      end
      """)

      compile(Path.join(support_dir, "corpus.ex"), """
      defmodule ArchLens.ScanTmpFixture.Corpus do
        @moduledoc false
        use ArchLens.Context, does: "a corpus of parity cases used only by the test suite"
      end

      defmodule ArchLens.ScanTmpFixture.Corpus.Entry do
        @moduledoc false
        def entry, do: :ok
      end
      """)

      blog = ArchLens.ScanTmpFixture.Blog
      corpus = [ArchLens.ScanTmpFixture.Corpus, ArchLens.ScanTmpFixture.Corpus.Entry]
      lib_root = Path.expand("lib", tmp)

      # :dev — only lib/ is compiled, so the raw module list is exactly [Blog].
      dev = render(modules: [blog])

      # :test — test/support is compiled in too; the lib-only filter converges the
      # module set back to [Blog], reproducing the :dev artifact byte-for-byte.
      test_filtered = render(modules: Scan.lib_only([blog | corpus], lib_root))
      assert test_filtered == dev

      # And prove the fixture genuinely would leak without the filter: unfiltered,
      # the artifact gains the corpus context and diverges from :dev.
      test_unfiltered = render(modules: [blog | corpus])
      refute test_unfiltered == dev
      assert test_unfiltered.markdown =~ "corpus"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp raw_app_modules(app) do
    _ = Application.load(app)
    {:ok, modules} = :application.get_key(app, :modules)
    modules
  end

  defp scope_for(modules) do
    Scope.resolve(
      app_namespace: ArchLens,
      modules: modules,
      scanned_resources: [],
      oban_workers: [],
      edges: []
    )
  end

  defp context_names(scope) do
    scope |> Contexts.resolve() |> Map.fetch!(:contexts) |> Enum.map(& &1.name)
  end

  defp render(overrides) do
    opts =
      Keyword.merge(
        [
          app_namespace: ArchLens.ScanTmpFixture,
          scanned_resources: [],
          oban_workers: [],
          edges: []
        ],
        overrides
      )

    {:ok, artifacts} = Architecture.render_artifacts(opts)
    artifacts
  end

  defp compile(path, source) do
    File.write!(path, source)
    Code.compile_file(path)
  end
end
