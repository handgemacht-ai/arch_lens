defmodule ArchLens.Collect.ExternalsTest do
  # async: false — the config-discovery case reads/writes app env.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Externals
  alias ArchLens.Edge

  defp swoosh(adapter), do: Module.concat(["Swoosh", "Adapters", adapter])

  defp write_config(name, contents) do
    dir = Path.join(System.tmp_dir!(), "arch_lens_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

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

    test "the default scan reads DIRECT deps only, not the transitive closure" do
      scanned = Externals.scanned_dep_names()
      direct = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0))
      closure = Mix.Project.deps_apps()

      assert Enum.sort(scanned) == Enum.sort(direct)

      # A vendor is a party the app itself chose to talk to; a transitive-only dep
      # (present in the closure but not declared directly) must never be scanned,
      # or it could fabricate an external system the app never opted into.
      transitive_only = closure -- direct
      assert transitive_only != []
      refute Enum.any?(transitive_only, &(&1 in scanned))
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

    test "discovers the configured mailer adapter from live app config as a fallback" do
      Application.put_env(:arch_lens, :test_mailer, adapter: swoosh("Mailgun"))
      on_exit(fn -> Application.delete_env(:arch_lens, :test_mailer) end)

      mailgun =
        Enum.find(Externals.swoosh_vendors(otp_app: :arch_lens), &(&1.vendor == "Mailgun"))

      assert mailgun
      assert [%{type: "swoosh_adapter", source: "runtime config"}] = mailgun.evidence
    end

    test "reads the prod mailer adapter from config files, independent of the live config" do
      # The dev/CI reality: live config carries only a Local (non-external) adapter,
      # yet the committed prod config names the real mailer. The old live-only read
      # silently omitted it; reading the config file makes discovery deterministic.
      Application.put_env(:arch_lens, :test_mailer, adapter: swoosh("Local"))
      on_exit(fn -> Application.delete_env(:arch_lens, :test_mailer) end)

      config_path =
        write_config("prod.exs", """
        import Config
        config :arch_lens, ArchLens.TestMailer, adapter: Swoosh.Adapters.Mailgun
        """)

      elements = Externals.swoosh_vendors(otp_app: :arch_lens, config_path: config_path)

      assert mailgun = Enum.find(elements, &(&1.vendor == "Mailgun"))
      assert [evidence] = mailgun.evidence
      assert evidence.type == "swoosh_adapter"
      assert evidence.value == "Swoosh.Adapters.Mailgun"
      assert evidence.source =~ "prod.exs"
    end

    test "emits no external mailer when only Local/Test adapters exist anywhere" do
      Application.put_env(:arch_lens, :test_mailer, adapter: swoosh("Test"))
      on_exit(fn -> Application.delete_env(:arch_lens, :test_mailer) end)

      config_path =
        write_config("prod_local.exs", """
        import Config
        config :arch_lens, ArchLens.TestMailer, adapter: Swoosh.Adapters.Local
        """)

      assert Externals.swoosh_vendors(otp_app: :arch_lens, config_path: config_path) == []
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
