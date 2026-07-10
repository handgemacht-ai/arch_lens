# Fixture "consuming app" for the generator tests, defined inline (rather than a
# separate helper file) so it is loaded as part of this `_test.exs`: real Ash
# resources declaring privacy via ArchLens.Privacy, a domain that lists some of
# them, and an embedded resource that no domain lists (found only by the module
# scan). Defining Ash resources at test runtime emits benign "Inspect protocol
# already consolidated" warnings — harmless, and unavoidable here since the
# fixtures can only live under test/generator/.

defmodule ArchLens.GenFixtures.Contact do
  @moduledoc false
  use Ash.Resource,
    domain: ArchLens.GenFixtures.Domain,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:contact)
    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:expires_at, :utc_datetime_usec)
  end
end

defmodule ArchLens.GenFixtures.Event do
  @moduledoc false
  # Retention declared, but no expiry field and no cleanup edge → not enforced.
  use Ash.Resource,
    domain: ArchLens.GenFixtures.Domain,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:usage)
    retention("P90D")
    legal_basis(:legitimate_interest)
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.GenFixtures.FeatureFlag do
  @moduledoc false
  use Ash.Resource,
    domain: ArchLens.GenFixtures.Domain,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end

  attributes do
    uuid_primary_key(:id)
  end
end

defmodule ArchLens.GenFixtures.EmbeddedNote do
  @moduledoc false
  # Embedded in another resource, so listed by no domain; only the module scan
  # surfaces it.
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:note)
    retention("P7D")
    legal_basis(:consent)
  end

  attributes do
    attribute(:body, :string)
  end
end

defmodule ArchLens.GenFixtures.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ArchLens.GenFixtures.Contact)
    resource(ArchLens.GenFixtures.Event)
    resource(ArchLens.GenFixtures.FeatureFlag)
  end
end

defmodule ArchLens.GenFixtures do
  @moduledoc false

  alias ArchLens.Edge

  def domain, do: ArchLens.GenFixtures.Domain

  @doc "The module-scan result: every fixture resource, including the embedded one."
  def scanned_resources do
    [
      ArchLens.GenFixtures.Contact,
      ArchLens.GenFixtures.Event,
      ArchLens.GenFixtures.FeatureFlag,
      ArchLens.GenFixtures.EmbeddedNote
    ]
  end

  @doc """
  Recorded edges: a cleanup oban-insert that enforces Contact's retention, plus a
  plain pubsub topic edge. Call-site file paths are repo-relative on purpose.
  """
  def edges do
    [
      %Edge{
        kind: :oban_insert,
        builder: ArchLens.GenFixtures.PurgeContacts,
        call_site: {ArchLens.GenFixtures.Contact, "lib/gen_fixtures/contact.ex", 12},
        target: ArchLens.GenFixtures.PurgeContacts,
        metadata: %{retention_cleanup_for: ArchLens.GenFixtures.Contact}
      },
      %Edge{
        kind: :topic,
        builder: ArchLens.GenFixtures.Topics,
        call_site: {ArchLens.GenFixtures.Event, "lib/gen_fixtures/event.ex", 7},
        target: "gen_fixtures:events"
      }
    ]
  end

  def oban_workers, do: [ArchLens.GenFixtures.PurgeContacts]

  @doc "Full, enforced scope options for the fixture app."
  def opts do
    [
      domains: [domain()],
      scanned_resources: scanned_resources(),
      edges: edges(),
      oban_workers: oban_workers()
    ]
  end
end

defmodule ArchLens.Generator.ArchitectureTest do
  # async: false — some cases exercise the shared edge Registry indirectly and
  # the generator loads modules; keep them serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Generator.{Architecture, Scan, Scope}
  alias ArchLens.GenFixtures

  describe "render/1 — S1 determinism" do
    test "two runs against an unchanged fixture app produce byte-identical markdown" do
      assert {:ok, first} = Architecture.render(GenFixtures.opts())
      assert {:ok, second} = Architecture.render(GenFixtures.opts())
      assert first == second
    end

    test "output carries no absolute filesystem path" do
      assert {:ok, md} = Architecture.render(GenFixtures.opts())
      refute md =~ File.cwd!()
      refute md =~ ~r{(^|[^a-z])/srv/}
      # the repo-relative call-site path survives, though
      assert md =~ "lib/gen_fixtures/contact.ex:12"
    end
  end

  describe "render/1 — S4 privacy + embedded discovery" do
    test "each resource's privacy posture is rendered" do
      {:ok, md} = Architecture.render(GenFixtures.opts())

      assert md =~ "### ArchLens.GenFixtures.Contact"
      assert md =~ "- Data category: `:contact`"
      assert md =~ "- Legal basis: `:consent`"

      assert md =~ "### ArchLens.GenFixtures.FeatureFlag"
      assert md =~ "- No personal data."
    end

    test "a domain-unregistered embedded resource still appears via the module scan" do
      {:ok, md} = Architecture.render(GenFixtures.opts())

      assert md =~ "### ArchLens.GenFixtures.EmbeddedNote"
      assert md =~ "- Discovered via module scan (no registered domain)."
    end

    test "Scope.resolve unions domain resources with the scan" do
      scope = Scope.resolve(GenFixtures.opts())

      assert ArchLens.GenFixtures.Contact in scope.domain_resources
      assert ArchLens.GenFixtures.EmbeddedNote in scope.resources
      refute ArchLens.GenFixtures.EmbeddedNote in scope.domain_resources
    end

    test "the module scan detects Ash resources and rejects non-resources" do
      modules = [ArchLens.Generator.Scan, ArchLens.GenFixtures.Contact, Enum]
      assert Scan.ash_resources_from_modules(modules) == [ArchLens.GenFixtures.Contact]
    end
  end

  describe "render/1 — S6 retention labeling" do
    test "an enforced retention is labeled distinctly from a declared-not-enforced one" do
      {:ok, md} = Architecture.render(GenFixtures.opts())

      assert md =~
               "- Retention: `P30D` — enforced (field `expires_at`, cleanup `ArchLens.GenFixtures.PurgeContacts`)"

      assert md =~ "- Retention: `P90D` — declared, not enforced"

      # the two labels are never rendered the same way
      refute md =~ "- Retention: `P90D` — enforced"
    end
  end

  describe "render/1 — completeness gate (S2)" do
    test "a resource missing any privacy declaration fails generation outright" do
      opts = [
        scanned_resources: [ArchLens.TestSupport.UndeclaredResource],
        edges: [],
        oban_workers: []
      ]

      assert {:error, {:undeclared_resources, [ArchLens.TestSupport.UndeclaredResource]}} =
               Architecture.render(opts)
    end

    test "render!/1 raises on an undeclared resource" do
      opts = [
        scanned_resources: [ArchLens.TestSupport.UndeclaredResource],
        edges: [],
        oban_workers: []
      ]

      assert_raise ArgumentError, ~r/privacy declaration missing/, fn ->
        Architecture.render!(opts)
      end
    end
  end

  describe "render/1 — empty Oban renders cleanly (S1)" do
    test "zero Oban workers and zero edges render explicit empty sections, no crash" do
      opts = [
        scanned_resources: [ArchLens.TestSupport.ValidPrivacyResource],
        edges: [],
        oban_workers: []
      ]

      assert {:ok, md} = Architecture.render(opts)
      assert md =~ "## Oban jobs"
      assert md =~ "_No Oban jobs registered._"
      assert md =~ "_No architectural edges recorded._"
    end
  end

  describe "check/2 — staleness gate (S2)" do
    setup do
      {:ok, fresh} = Architecture.render(GenFixtures.opts())
      dir = Path.join(System.tmp_dir!(), "arch_lens_check_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "architecture.gen.md")
      on_exit(fn -> File.rm_rf(dir) end)
      %{fresh: fresh, path: path}
    end

    test "an up-to-date committed artifact passes", %{fresh: fresh, path: path} do
      File.write!(path, fresh)
      assert Architecture.check(path, fresh) == :ok
    end

    test "a mutated privacy declaration makes check fail, naming the artifact", %{
      fresh: fresh,
      path: path
    } do
      # The committed doc still carries Contact's PRE-mutation retention (`P45D`),
      # while the current code renders `P30D` — i.e. someone changed one privacy
      # declaration without re-running the generator.
      committed = String.replace(fresh, "`P30D`", "`P45D`")
      assert committed != fresh
      File.write!(path, committed)

      assert {:drift, ^path, reason} = Architecture.check(path, fresh)
      assert reason =~ "differs"
    end

    test "a missing committed artifact is drift, naming the artifact", %{
      fresh: fresh,
      path: path
    } do
      assert {:drift, ^path, reason} = Architecture.check(path, fresh)
      assert reason =~ "missing"
    end
  end
end
