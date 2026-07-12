defmodule ArchLens.FlowDslFixtures.App do
  @moduledoc false
  use ArchLens.System

  architecture do
    identity(:havi, name: "HAVI", aliases: ["havi", "havi.handgemacht.ai"])

    ignore_externals([:opentelemetry])

    external(:stripe,
      via: :http,
      target: "https://api.stripe.com",
      does: "billing",
      evidence: [dep: :stripity_stripe]
    )

    external(:docker,
      via: :subprocess,
      target: "docker",
      does: "containers",
      evidence: [manual: "shelled out via System.cmd"]
    )

    flow :billing_sync do
      does("the billing sync path")
      context(:billing, does: "settles the invoice")
      external(:stripe)
    end

    flow :annotation_capture do
      does("the capture path")
      entry_point("POST /api/annotations", does: "extension posts the envelope")
      context(:annotations, does: "persists the envelope")
      context(:workers)
      external(:stripe, unverified: true)
    end
  end
end

defmodule ArchLens.FlowDslFixtures.Accounts do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

  architecture do
    does("users and workspaces")
    interface(["MyAppWeb.AccountController", "MyAppWeb.SessionController"])
  end

  resources do
  end
end

defmodule ArchLens.FlowDslFixtures.Billing do
  @moduledoc "Subscriptions and invoices."
  use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

  resources do
  end
end

defmodule ArchLens.FlowDslFixtures.Judge do
  @moduledoc false
  use ArchLens.Context,
    does: "scores copy",
    interface: ["MyAppWeb.JudgeController"]
end

defmodule ArchLens.FlowDslFixtures.Ingest do
  @moduledoc false
  use ArchLens.Context, does: "ingests events"
end

defmodule ArchLens.FlowDslTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.Context.Info, as: ContextInfo
  alias ArchLens.Domain
  alias ArchLens.FlowDslFixtures.App
  alias ArchLens.System.{Declared, Flow, Identity, Info, Validate}

  describe "flow entity — Info.flows/1" do
    test "flows are read as Flow structs, sorted by name" do
      flows = Info.flows(App)

      assert Enum.all?(flows, &match?(%Flow{}, &1))
      assert Enum.map(flows, & &1.name) == [:annotation_capture, :billing_sync]
    end

    test "steps keep declaration order, each with the right kind and ref" do
      capture = Enum.find(Info.flows(App), &(&1.name == :annotation_capture))

      assert Enum.map(capture.steps, &{&1.kind, &1.ref}) == [
               {:entry_point, "POST /api/annotations"},
               {:context, :annotations},
               {:context, :workers},
               {:external, :stripe}
             ]

      assert Enum.all?(capture.steps, &match?(%Flow.Step{}, &1))
    end

    test "a step carries its verbatim does and unverified flag" do
      capture = Enum.find(Info.flows(App), &(&1.name == :annotation_capture))
      [entry, annotations, workers, stripe] = capture.steps

      assert entry.does == "extension posts the envelope"
      assert annotations.does == "persists the envelope"
      # does is optional; a bare step leaves it nil and defaults unverified to false
      assert workers.does == nil
      refute workers.unverified
      # the escape hatch: the external hop is asserted, not proven
      assert stripe.unverified
    end

    test "the flow's verbatim does is carried" do
      capture = Enum.find(Info.flows(App), &(&1.name == :annotation_capture))
      assert capture.does == "the capture path"
    end
  end

  describe "identity entity — Info.identity/1" do
    test "reads the declared identity struct with its aliases" do
      identity = Info.identity(App)

      assert %Identity{id: :havi, name: "HAVI"} = identity
      assert identity.aliases == ["havi", "havi.handgemacht.ai"]
    end

    test "a module that declares none reads back nil" do
      assert Info.identity(Enum) == nil
    end

    test "declaring two identities is rejected at compile time" do
      code = """
      defmodule ArchLens.FlowDslTest.TwoIdentitiesFixture do
        use ArchLens.System

        architecture do
          identity :one
          identity :two
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/at most one identity/, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end

  describe "ignore_externals option — Info.ignore_externals/1" do
    test "reads the declared list" do
      assert Info.ignore_externals(App) == [:opentelemetry]
    end

    test "a non-ArchLens.System module reads back empty" do
      assert Info.ignore_externals(Enum) == []
    end
  end

  describe "external evidence hint" do
    test "a declared external carries its evidence keyword hint" do
      externals = Info.externals(App)

      stripe = Enum.find(externals, &(&1.name == :stripe))
      docker = Enum.find(externals, &(&1.name == :docker))

      assert stripe.evidence == [dep: :stripity_stripe]
      assert docker.evidence == [manual: "shelled out via System.cmd"]
    end

    test "an external with no evidence hint defaults to []" do
      code = """
      defmodule ArchLens.FlowDslTest.NoEvidenceFixture do
        use ArchLens.System

        architecture do
          external :plain, via: :http, target: "https://x.example", does: "y"
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert [external] = Info.externals(mod)
      assert external.evidence == []
    end
  end

  describe "duplicate flow names" do
    test "two flows with the same name are rejected at compile time" do
      code = """
      defmodule ArchLens.FlowDslTest.DuplicateFlowFixture do
        use ArchLens.System

        architecture do
          flow :dup do
            does "a"
          end

          flow :dup do
            does "b"
          end
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/duplicate flow/, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end

  describe "architecture/1 includes flows" do
    test "groups actors, externals, contexts, and flows" do
      arch = Info.architecture(App)

      assert Map.has_key?(arch, :flows)
      assert Enum.map(arch.flows, & &1.name) == [:annotation_capture, :billing_sync]
    end
  end

  describe "Declared.build/1 carries the new surface (no validation)" do
    test "flows are normalized to source-tagged maps preserving step order" do
      %{flows: flows} = Declared.build(App)

      capture = Enum.find(flows, &(&1.name == :annotation_capture))
      assert capture.source == "declared"
      assert capture.does == "the capture path"

      assert Enum.map(capture.steps, & &1.kind) == [:entry_point, :context, :context, :external]

      assert Enum.map(capture.steps, & &1.ref) == [
               "POST /api/annotations",
               :annotations,
               :workers,
               :stripe
             ]

      stripe_step = List.last(capture.steps)
      assert stripe_step.unverified
    end

    test "the town identity is normalized to a source-tagged map" do
      %{identity: identity} = Declared.build(App)

      assert identity == %{
               id: :havi,
               name: "HAVI",
               aliases: ["havi", "havi.handgemacht.ai"],
               source: "declared"
             }
    end

    test "declared externals carry the evidence hint" do
      %{externals: externals} = Declared.build(App)

      stripe = Enum.find(externals, &(&1.name == :stripe))
      assert stripe.evidence_hint == [dep: :stripity_stripe]
    end

    test "a System with no identity yields a nil identity" do
      code = """
      defmodule ArchLens.FlowDslTest.NoIdentityFixture do
        use ArchLens.System

        architecture do
          actor :dev, does: "builds"
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert %{identity: nil, flows: []} = Declared.build(mod)
    end
  end

  describe "entry_point_uses widening (:cron / :channel)" do
    defp actor(uses),
      do: %{name: :sched, uses: uses, does: "x", source: "declared"}

    defp declared(actors), do: %{actors: actors, externals: [], contexts: []}

    test "the vocabulary is widened with :cron and :channel" do
      assert :cron in Validate.entry_point_uses()
      assert :channel in Validate.entry_point_uses()
    end

    test "an actor may use :cron when a cron entry point was collected" do
      ctx = Validate.context(%{entry_points: [%{kind: :cron}]})
      assert {:ok, []} = Validate.validate(declared([actor([:cron])]), ctx)
    end

    test ":channel is valid vocabulary and skips (not rejects) when nothing was collected" do
      ctx = Validate.context(%{entry_points: []})

      assert {:ok, [warning]} = Validate.validate(declared([actor([:channel])]), ctx)
      assert warning =~ "entry points not collected"
    end

    test "an atom outside the widened vocabulary is still rejected" do
      ctx = Validate.context(%{entry_points: [%{kind: :cron}]})

      assert {:error, [message]} = Validate.validate(declared([actor([:telepathy])]), ctx)
      assert message =~ "not a known entry-point kind"
      assert message =~ ":cron"
    end
  end

  describe "interface option — Domain and plain Context" do
    alias ArchLens.FlowDslFixtures.{Accounts, Billing, Ingest, Judge}

    test "ArchLens.Domain.interface/1 reads the declared namespaces" do
      assert Domain.interface(Accounts) ==
               ["MyAppWeb.AccountController", "MyAppWeb.SessionController"]
    end

    test "a domain that declares no interface reads back empty" do
      assert Domain.interface(Billing) == []
    end

    test "ArchLens.Context.Info.interface/1 reads the annotated namespaces" do
      assert ContextInfo.interface(Judge) == ["MyAppWeb.JudgeController"]
    end

    test "a context that declares no interface reads back empty" do
      assert ContextInfo.interface(Ingest) == []
    end

    test "a non-list interface fails the compile fast" do
      code = """
      defmodule ArchLens.FlowDslTest.BadInterfaceFixture do
        use ArchLens.Context, interface: "MyAppWeb.Thing"
      end
      """

      assert_raise ArgumentError, ~r/literal value for `interface`/, fn ->
        capture_io(:stderr, fn -> Code.compile_string(code) end)
      end
    end
  end
end
