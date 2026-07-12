defmodule ArchLens.System.ExternalEvidenceTest do
  use ExUnit.Case, async: true

  alias ArchLens.Generator.Sections.ExternalSystems
  alias ArchLens.System.{ExternalEvidence, ExternalMerge}

  defp ctx(opts) do
    %{
      external_ids: MapSet.new(Keyword.get(opts, :ids, [])),
      external_hosts: MapSet.new(Keyword.get(opts, :hosts, [])),
      deps: MapSet.new(Keyword.get(opts, :deps, [])),
      known_modules: MapSet.new(Keyword.get(opts, :known_modules, []))
    }
  end

  defp external(fields), do: Map.new(fields)

  describe "resolve/2 — implicit corroboration" do
    test "an id in the collected set corroborates" do
      external = external(name: :stripe, target: "https://api.stripe.com")

      assert {:corroborated, []} =
               ExternalEvidence.resolve(external, ctx(ids: ["external:stripe"]))
    end

    test "a target host in the collected boundary hosts corroborates" do
      external = external(name: :acme, target: "https://api.acme.io")

      assert {:corroborated, []} =
               ExternalEvidence.resolve(external, ctx(hosts: ["api.acme.io"]))
    end

    test "an implicit match wins even when a declared hint would not resolve" do
      external =
        external(name: :stripe, target: "https://api.stripe.com", evidence_hint: [dep: :nope])

      assert {:corroborated, []} =
               ExternalEvidence.resolve(external, ctx(ids: ["external:stripe"]))
    end

    test "a bare name collision with a dependency does not corroborate" do
      external = external(name: :jason, target: "https://fabricated.example")

      assert {:unevidenced, :no_evidence} =
               ExternalEvidence.resolve(external, ctx(deps: ["jason", "phoenix"]))
    end
  end

  describe "resolve/2 — evidence hint resolution" do
    test "a dep: hint resolves against the direct dependencies" do
      external =
        external(
          name: :stripe,
          target: "https://api.stripe.com",
          evidence_hint: [dep: :stripity_stripe]
        )

      assert {:corroborated, [%{type: "dep", value: "stripity_stripe", source: "declared_hint"}]} =
               ExternalEvidence.resolve(external, ctx(deps: ["stripity_stripe"]))
    end

    test "a module: hint resolves against a real app-module prefix" do
      external =
        external(name: :mailer, target: "smtp://mail", evidence_hint: [module: "MyApp.Mailer"])

      assert {:corroborated, [%{type: "module", value: "MyApp.Mailer", source: "declared_hint"}]} =
               ExternalEvidence.resolve(external, ctx(known_modules: ["MyApp.Mailer.Client"]))
    end

    test "a host: hint resolves against a collected boundary host" do
      external =
        external(name: :brevo, target: "smtp://brevo", evidence_hint: [host: "api.brevo.com"])

      assert {:corroborated,
              [%{type: "http_boundary", value: "api.brevo.com", source: "declared_hint"}]} =
               ExternalEvidence.resolve(external, ctx(hosts: ["api.brevo.com"]))
    end

    test "a dep: hint that names no direct dependency is itself unevidenced" do
      external =
        external(
          name: :stripe,
          target: "https://api.stripe.com",
          evidence_hint: [dep: :not_a_dep]
        )

      assert {:unevidenced, {:unresolved_hint, {:dep, :not_a_dep}}} =
               ExternalEvidence.resolve(external, ctx(deps: ["jason"]))
    end

    test "a module: hint that names no module is itself unevidenced" do
      external =
        external(name: :mailer, target: "smtp://mail", evidence_hint: [module: "No.Such.Module"])

      assert {:unevidenced, {:unresolved_hint, {:module, "No.Such.Module"}}} =
               ExternalEvidence.resolve(external, ctx(known_modules: ["MyApp.Other"]))
    end

    test "a host: hint absent from the collected boundaries is unevidenced" do
      external =
        external(name: :brevo, target: "smtp://brevo", evidence_hint: [host: "nope.example"])

      assert {:unevidenced, {:unresolved_hint, {:host, "nope.example"}}} =
               ExternalEvidence.resolve(external, ctx(hosts: ["api.brevo.com"]))
    end

    test "an unknown hint key is unevidenced" do
      external = external(name: :thing, target: "x", evidence_hint: [somewhere: "here"])

      assert {:unevidenced, {:unknown_hint, [:somewhere]}} =
               ExternalEvidence.resolve(external, ctx([]))
    end
  end

  describe "resolve/2 — manual escape hatch" do
    test "a non-empty manual reason corroborates by assertion" do
      external =
        external(
          name: :docker,
          target: "docker",
          evidence_hint: [manual: "shelled out via System.cmd"]
        )

      assert {:manual, [%{type: "manual", value: "shelled out via System.cmd"}]} =
               ExternalEvidence.resolve(external, ctx([]))
    end

    test "a blank manual reason is rejected" do
      external = external(name: :docker, target: "docker", evidence_hint: [manual: "   "])

      assert {:unevidenced, :empty_manual_reason} = ExternalEvidence.resolve(external, ctx([]))
    end

    test "a bare manual: without a string reason is rejected" do
      external = external(name: :docker, target: "docker", evidence_hint: [manual: true])

      assert {:unevidenced, :manual_needs_reason} = ExternalEvidence.resolve(external, ctx([]))
    end
  end

  describe "resolve/2 — no evidence at all" do
    test "an external with nothing is unevidenced" do
      external = external(name: :ghost, target: "https://ghost.example")

      assert {:unevidenced, :no_evidence} = ExternalEvidence.resolve(external, ctx([]))
    end
  end

  describe "stamp/2" do
    test "a collapsed external carries the collected evidence" do
      external = external(name: :stripe, target: "https://api.stripe.com")
      collected = %{id: "external:stripe", evidence: [%{type: "dep", value: "stripity_stripe"}]}

      assert {"corroborated", ["collected", "declared"],
              [%{type: "dep", value: "stripity_stripe"}]} =
               ExternalEvidence.stamp(external, collected)
    end

    test "a resolved code hint stamps corroborated with the synthesized hint evidence" do
      external =
        external(
          name: :stripe,
          target: "https://api.stripe.com",
          evidence_hint: [dep: :stripity_stripe]
        )

      assert {"corroborated", ["collected", "declared"],
              [%{type: "dep", value: "stripity_stripe", source: "declared_hint"}]} =
               ExternalEvidence.stamp(external, nil)
    end

    test "a manual external stamps manual with the reason as evidence" do
      external = external(name: :docker, target: "docker", evidence_hint: [manual: "shelled out"])

      assert {"manual", ["declared"], [%{type: "manual", value: "shelled out"}]} =
               ExternalEvidence.stamp(external, nil)
    end

    test "an external with no evidence stamps manual with empty evidence" do
      external = external(name: :ghost, target: "https://ghost.example")

      assert {"manual", ["declared"], []} = ExternalEvidence.stamp(external, nil)
    end
  end

  describe "matches?/2" do
    test "matches by shared stable id" do
      external = external(name: :stripe, target: "https://api.stripe.com")
      collected = %{id: "external:stripe", vendor: "Stripe"}

      assert ExternalEvidence.matches?(external, collected)
    end

    test "matches by target host against a collected boundary host" do
      external = external(name: :acme, target: "https://api.acme.io")

      collected = %{
        id: "external:acme-io",
        vendor: "acme.io",
        evidence: [%{type: "http_boundary", value: "https://api.acme.io"}]
      }

      assert ExternalEvidence.matches?(external, collected)
    end

    test "does not match an unrelated third party" do
      external = external(name: :ghost, target: "https://ghost.example")
      collected = %{id: "external:stripe", vendor: "Stripe"}

      refute ExternalEvidence.matches?(external, collected)
    end
  end

  describe "gate/1 — detected-without-declaration completeness" do
    test "passes when every collected external is declared" do
      collected = [
        %{
          id: "external:stripe",
          vendor: "Stripe",
          evidence: [%{type: "dep", value: "stripity_stripe"}]
        }
      ]

      declared = [%{name: :stripe, target: "https://api.stripe.com"}]

      assert :ok = ExternalEvidence.gate(%{collected: collected, declared: declared})
    end

    test "one clean host declaration collapses an ugly host-derived collected vendor" do
      collected = [
        %{
          id: "external:brevo-com",
          vendor: "brevo.com",
          evidence: [%{type: "http_boundary", value: "https://api.brevo.com"}]
        }
      ]

      declared = [%{name: :brevo, target: "https://api.brevo.com"}]

      assert :ok = ExternalEvidence.gate(%{collected: collected, declared: declared})
    end

    test "fails, sorted and de-duplicated, for undeclared vendors" do
      collected = [
        %{id: "external:zebra", vendor: "Zebra", evidence: []},
        %{id: "external:alpha", vendor: "Alpha", evidence: []},
        %{id: "external:alpha", vendor: "Alpha", evidence: []}
      ]

      assert {:error, {:undeclared_externals, ["Alpha", "Zebra"]}} =
               ExternalEvidence.gate(%{collected: collected, declared: []})
    end

    test "ignore_externals covers a collected vendor by lenient slug match" do
      collected = [
        %{
          id: "external:opentelemetry",
          vendor: "OpenTelemetry",
          evidence: [%{type: "dep", value: "opentelemetry_api"}]
        }
      ]

      assert :ok =
               ExternalEvidence.gate(%{
                 collected: collected,
                 declared: [],
                 ignore_externals: [:opentelemetry]
               })
    end

    test "ignore_externals matches a dependency evidence name, not just the vendor" do
      collected = [
        %{
          id: "external:opentelemetry",
          vendor: "OpenTelemetry",
          evidence: [%{type: "dep", value: "opentelemetry_exporter_otlp"}]
        }
      ]

      assert :ok =
               ExternalEvidence.gate(%{
                 collected: collected,
                 declared: [],
                 ignore_externals: [:opentelemetry_exporter_otlp]
               })
    end
  end

  describe "ExternalMerge.merge/3 — three-state verification end to end" do
    test "a declared external backed by a collected one is corroborated with the collected evidence" do
      collected = [
        %{
          id: "external:stripe",
          vendor: "Stripe",
          evidence: [%{type: "dep", value: "stripity_stripe"}]
        }
      ]

      declared = [
        %{
          name: :stripe,
          via: :http,
          target: "https://api.stripe.com",
          does: "billing",
          evidence_hint: []
        }
      ]

      assert [element] = ExternalMerge.merge(collected, declared, [])
      assert element.verification == "corroborated"
      assert element.provenance == ["collected", "declared"]
      assert element.source == "collected"
      assert element.evidence == [%{type: "dep", value: "stripity_stripe"}]
    end

    test "a declared external with a resolving hint is corroborated by the synthesized hint" do
      declared = [
        %{
          name: :stripe,
          via: :http,
          target: "https://api.stripe.com",
          does: "billing",
          evidence_hint: [dep: :stripity_stripe]
        }
      ]

      assert [element] = ExternalMerge.merge([], declared, [])
      assert element.verification == "corroborated"
      assert element.provenance == ["collected", "declared"]

      assert element.evidence == [
               %{type: "dep", value: "stripity_stripe", source: "declared_hint"}
             ]
    end

    test "a declared-only external with a manual reason is manual" do
      declared = [
        %{
          name: :docker,
          via: :subprocess,
          target: "docker",
          does: "containers",
          evidence_hint: [manual: "shelled out via System.cmd"]
        }
      ]

      assert [element] = ExternalMerge.merge([], declared, [])
      assert element.verification == "manual"
      assert element.provenance == ["declared"]
      assert element.evidence == [%{type: "manual", value: "shelled out via System.cmd"}]
    end

    test "a collected-only external renders tagged ignored, never dropped" do
      collected = [
        %{id: "external:sentry", vendor: "Sentry", evidence: [%{type: "dep", value: "sentry"}]}
      ]

      assert [element] = ExternalMerge.merge(collected, [], [])
      assert element.verification == "ignored"
      assert element.provenance == ["collected"]
      assert element.vendor == "Sentry"
    end
  end

  describe "ExternalSystems rendering carries verification, verbatim does, and evidence" do
    defp render(elements) do
      elements |> ExternalSystems.to_json() |> ExternalSystems.render() |> Enum.join("\n")
    end

    test "a corroborated declared external renders its label, does, tag, and evidence" do
      collected = [
        %{
          id: "external:stripe",
          vendor: "Stripe",
          evidence: [%{type: "dep", value: "stripity_stripe"}]
        }
      ]

      declared = [
        %{
          name: :stripe,
          via: :http,
          target: "https://api.stripe.com",
          does: "billing",
          evidence_hint: []
        }
      ]

      md = render(ExternalMerge.merge(collected, declared, []))

      assert md =~ "## External systems"
      assert md =~ "stripe → https://api.stripe.com (http)"
      assert md =~ "billing"
      assert md =~ "`corroborated`"
      assert md =~ "dep stripity_stripe"
    end

    test "a manual external renders its verbatim does and the manual tag" do
      declared = [
        %{
          name: :docker,
          via: :subprocess,
          target: "docker",
          does: "containers",
          evidence_hint: [manual: "shelled out via System.cmd"]
        }
      ]

      md = render(ExternalMerge.merge([], declared, []))

      assert md =~ "docker → docker (subprocess)"
      assert md =~ "containers"
      assert md =~ "`manual`"
    end

    test "a collected-only ignored external renders its vendor and tag with no invented purpose" do
      collected = [
        %{id: "external:sentry", vendor: "Sentry", evidence: [%{type: "dep", value: "sentry"}]}
      ]

      md = render(ExternalMerge.merge(collected, [], []))

      assert md =~ "**Sentry**"
      assert md =~ "`ignored`"
      refute md =~ "Sentry** —"
    end
  end
end
