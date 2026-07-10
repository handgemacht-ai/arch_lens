defmodule ArchLens.Collect.ExternalsTest do
  # async: false — the config-discovery case reads/writes app env.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Externals
  alias ArchLens.Edge

  defp swoosh(adapter), do: Module.concat(["Swoosh", "Adapters", adapter])

  defp boundary(target, name \\ :vendor) do
    %Edge{
      kind: :http_boundary,
      builder: {ArchLens.CollectFixtures.Custom, name},
      target: target,
      call_sites: [{"lib/custom.ex", 1}]
    }
  end

  describe "dep_vendors/1" do
    test "maps known dependencies to vendors and excludes pure HTTP clients" do
      elements =
        Externals.dep_vendors(deps: [:stripity_stripe, :sentry, :req, :finch, :tesla, :hackney])

      assert Enum.map(elements, & &1.vendor) |> Enum.sort() == ["Sentry", "Stripe"]

      stripe = Enum.find(elements, &(&1.vendor == "Stripe"))
      assert stripe.id == "external:stripe"
      assert stripe.category == "payments"
      assert stripe.source == "collected"
      assert stripe.evidence == [%{type: "dep", value: "stripity_stripe"}]
    end

    test "accepts dependency tuples as well as bare atoms" do
      assert [%{vendor: "Stripe"}] = Externals.dep_vendors(deps: [{:stripity_stripe, "~> 3.0"}])
    end

    test "collapses every opentelemetry* dependency into one OpenTelemetry system" do
      elements =
        Externals.collect(
          deps: [:opentelemetry, :opentelemetry_api, :opentelemetry_exporter],
          edges: []
        )

      assert [otel] = elements
      assert otel.vendor == "OpenTelemetry"
      assert otel.category == "observability"
      assert length(otel.evidence) == 3
    end

    test "an unmapped dependency contributes no external system" do
      assert Externals.dep_vendors(deps: [:phoenix, :jason]) == []
    end
  end

  describe "swoosh_vendors/1" do
    test "maps swoosh adapters to their providers, skipping local/test adapters" do
      adapters = [swoosh("Sendgrid"), swoosh("AmazonSES"), swoosh("Local"), swoosh("Test")]

      elements = Externals.swoosh_vendors(swoosh_adapters: adapters)

      assert Enum.map(elements, & &1.vendor) |> Enum.sort() == ["Amazon SES", "Sendgrid"]

      ses = Enum.find(elements, &(&1.vendor == "Amazon SES"))
      assert ses.id == "external:amazon-ses"
      assert ses.category == "email"
      assert ses.evidence == [%{type: "swoosh_adapter", value: "Swoosh.Adapters.AmazonSES"}]
    end

    test "discovers the configured mailer adapter from the app config" do
      Application.put_env(:arch_lens, :test_mailer, adapter: swoosh("Mailgun"))
      on_exit(fn -> Application.delete_env(:arch_lens, :test_mailer) end)

      assert Enum.any?(Externals.swoosh_vendors(otp_app: :arch_lens), &(&1.vendor == "Mailgun"))
    end
  end

  describe "boundary_vendors/1" do
    test "canonicalises a known boundary host to its vendor" do
      assert [stripe] = Externals.boundary_vendors(edges: [boundary("https://api.stripe.com")])
      assert stripe.vendor == "Stripe"
      assert stripe.id == "external:stripe"
      assert stripe.evidence == [%{type: "http_boundary", value: "https://api.stripe.com"}]
    end

    test "an unknown host falls back to a readable vendor with no category" do
      assert [sys] = Externals.boundary_vendors(edges: [boundary("https://api.acme.io/v1")])
      assert sys.vendor == "acme.io"
      assert sys.id == "external:acme-io"
      refute Map.has_key?(sys, :category)
    end

    test "ignores non-http_boundary edges" do
      topic = %Edge{kind: :topic, builder: ArchLens.CollectFixtures.Custom, target: "app:topic"}
      assert Externals.boundary_vendors(edges: [topic]) == []
    end
  end

  describe "collect/1 — merge by canonical vendor" do
    test "an http_boundary edge and its dependency become one system with both evidences" do
      elements =
        Externals.collect(
          deps: [:stripity_stripe],
          edges: [boundary("https://api.stripe.com")]
        )

      assert [stripe] = elements
      assert stripe.vendor == "Stripe"
      assert stripe.id == "external:stripe"
      assert stripe.category == "payments"

      assert Enum.sort_by(stripe.evidence, &{&1.type, &1.value}) == [
               %{type: "dep", value: "stripity_stripe"},
               %{type: "http_boundary", value: "https://api.stripe.com"}
             ]
    end

    test "the collected list is deterministically sorted by id and reproducible" do
      opts = [
        deps: [:stripity_stripe, :sentry],
        edges: [boundary("https://api.acme.io")]
      ]

      first = Externals.collect(opts)
      ids = Enum.map(first, & &1.id)

      assert ids == Enum.sort(ids)
      assert Externals.collect(opts) == first
    end
  end
end
