defmodule ArchLens.Collect.Externals do
  @moduledoc """
  Collects the third-party systems the host app talks to into
  `ArchLens.Generator.Scope`'s `external_systems` seam.

  Three evidence sources fold into one deterministic, id-sorted list, every element
  tagged `source: "collected"`:

    * **dependencies** — a static dep → vendor map read from the host app's
      `Mix.Project` deps: `stripity_stripe` → Stripe, `sentry` → Sentry, any
      `opentelemetry*` dep → the OpenTelemetry collector. Pure HTTP client
      libraries (`req`, `tesla`, `finch`, `mint`, `hackney`, `httpoison`, `gun`)
      are transport, not vendors, and are deliberately excluded.
    * **Swoosh adapters** — the configured mailer adapter names the provider
      (`Swoosh.Adapters.Sendgrid` → Sendgrid, `…Mailgun` → Mailgun, `…AmazonSES`
      → Amazon SES). Adapters are read from the app's config; local/test adapters
      are not external systems.
    * **HTTP boundary edges** — every `:http_boundary` `ArchLens.Edge` already
      collected, its target host canonicalised to a vendor.

  The three sources are **merged by canonical vendor**: an `:http_boundary` edge
  naming `api.stripe.com` and the `stripity_stripe` dependency are one external
  system whose evidence lists both. Merging is deterministic — evidence entries are
  de-duplicated and sorted.

  `arch_lens` takes no hard dependency on any vendor SDK: Mix and app config are
  read behind guards, and unknown deps/hosts degrade to a readable fallback vendor.

  ## Options

    * `:otp_app` — the host OTP application (drives Swoosh-adapter config discovery).
    * `:deps` — override the dependency list (atoms or dep tuples); defaults to the
      host `Mix.Project`'s deps.
    * `:edges` — the recorded edges to mine `:http_boundary` targets from.
    * `:swoosh_adapters` — override the discovered Swoosh adapter modules.
  """

  alias ArchLens.Edge

  @dep_vendors %{
    stripity_stripe: {"Stripe", "payments"},
    sentry: {"Sentry", "error-tracking"}
  }

  # Transport libraries — HTTP clients that carry traffic but are not themselves an
  # external party. Named for documentation; excluded by simply not being vendors.
  @http_clients ~w(req tesla finch mint hackney httpoison gun castore)a

  @host_vendors %{
    "api.stripe.com" => {"Stripe", "payments"},
    "files.stripe.com" => {"Stripe", "payments"},
    "api.sendgrid.com" => {"Sendgrid", "email"},
    "api.mailgun.net" => {"Mailgun", "email"},
    "api.postmarkapp.com" => {"Postmark", "email"},
    "sentry.io" => {"Sentry", "error-tracking"}
  }

  @domain_vendors [
    {"stripe.com", {"Stripe", "payments"}},
    {"sendgrid.com", {"Sendgrid", "email"}},
    {"mailgun.net", {"Mailgun", "email"}},
    {"sentry.io", {"Sentry", "error-tracking"}}
  ]

  @swoosh_providers %{
    "Sendgrid" => "Sendgrid",
    "Mailgun" => "Mailgun",
    "AmazonSES" => "Amazon SES",
    "Postmark" => "Postmark",
    "SparkPost" => "SparkPost",
    "SocketLabs" => "SocketLabs",
    "MailPace" => "MailPace",
    "Mandrill" => "Mandrill",
    "SMTP2GO" => "SMTP2GO",
    "SMTP" => "SMTP",
    "Sendinblue" => "Brevo",
    "Brevo" => "Brevo"
  }

  # Local/test adapters deliver nowhere external.
  @non_vendor_swoosh ~w(Local Test)

  @type evidence :: %{type: String.t(), value: String.t()}
  @type element :: %{
          required(:id) => String.t(),
          required(:vendor) => String.t(),
          required(:source) => String.t(),
          required(:evidence) => [evidence()],
          optional(:category) => String.t()
        }

  @doc """
  The merged, id-sorted external-system list for `Scope.external_systems`.

  Unions dependency vendors, Swoosh providers, and `:http_boundary` edge targets,
  merging by canonical vendor so each external party appears once with every
  evidence listed.
  """
  @spec collect(keyword()) :: [element()]
  def collect(opts \\ []) do
    (dep_vendors(opts) ++ swoosh_vendors(opts) ++ boundary_vendors(opts))
    |> merge_by_id()
    |> Enum.sort_by(& &1.id)
  end

  @doc "External-system elements derived from the host app's dependencies."
  @spec dep_vendors(keyword()) :: [element()]
  def dep_vendors(opts) do
    opts
    |> deps()
    |> Enum.flat_map(&dep_vendor/1)
  end

  @doc "External-system elements derived from the configured Swoosh adapters."
  @spec swoosh_vendors(keyword()) :: [element()]
  def swoosh_vendors(opts) do
    opts
    |> swoosh_adapters()
    |> Enum.flat_map(&swoosh_vendor/1)
  end

  @doc "External-system elements derived from `:http_boundary` edge targets."
  @spec boundary_vendors(keyword()) :: [element()]
  def boundary_vendors(opts) do
    opts
    |> Keyword.get(:edges, [])
    |> Enum.filter(&http_boundary?/1)
    |> Enum.map(&boundary_vendor/1)
  end

  # --- dependencies -------------------------------------------------------

  defp deps(opts) do
    opts
    |> Keyword.get_lazy(:deps, &host_deps/0)
    |> Enum.map(&dep_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp host_deps do
    cond do
      not Code.ensure_loaded?(Mix.Project) -> []
      function_exported?(Mix.Project, :deps_apps, 0) -> Mix.Project.deps_apps()
      true -> Mix.Project.config()[:deps] || []
    end
  rescue
    _ -> []
  end

  defp dep_name(dep) when is_atom(dep), do: dep
  defp dep_name(dep) when is_tuple(dep) and tuple_size(dep) >= 1, do: elem(dep, 0)
  defp dep_name(_dep), do: nil

  defp dep_vendor(dep) do
    cond do
      dep in @http_clients ->
        []

      Map.has_key?(@dep_vendors, dep) ->
        {vendor, category} = Map.fetch!(@dep_vendors, dep)
        [element(vendor, category, dep_evidence(dep))]

      opentelemetry?(dep) ->
        [element("OpenTelemetry", "observability", dep_evidence(dep))]

      true ->
        []
    end
  end

  defp opentelemetry?(dep), do: String.starts_with?(Atom.to_string(dep), "opentelemetry")

  defp dep_evidence(dep), do: %{type: "dep", value: Atom.to_string(dep)}

  # --- Swoosh -------------------------------------------------------------

  defp swoosh_adapters(opts) do
    opts
    |> Keyword.get_lazy(:swoosh_adapters, fn -> discover_swoosh_adapters(opts) end)
    |> Enum.filter(&swoosh_adapter?/1)
    |> Enum.uniq()
  end

  defp discover_swoosh_adapters(opts) do
    case Keyword.get(opts, :otp_app) do
      nil ->
        []

      app ->
        app
        |> Application.get_all_env()
        |> Enum.flat_map(fn {_key, value} -> adapter_from_config(value) end)
        |> Enum.uniq()
    end
  rescue
    _ -> []
  end

  defp adapter_from_config(config) when is_list(config) do
    case Keyword.get(config, :adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) -> [adapter]
      _ -> []
    end
  end

  defp adapter_from_config(_config), do: []

  defp swoosh_adapter?(module) do
    is_atom(module) and String.starts_with?(name(module), "Swoosh.Adapters.")
  end

  defp swoosh_vendor(adapter) do
    "Swoosh.Adapters." <> provider = name(adapter)

    if provider in @non_vendor_swoosh do
      []
    else
      vendor = Map.get(@swoosh_providers, provider, provider)
      [element(vendor, "email", %{type: "swoosh_adapter", value: name(adapter)})]
    end
  end

  # --- HTTP boundary edges ------------------------------------------------

  defp http_boundary?(%Edge{kind: :http_boundary}), do: true
  defp http_boundary?(_edge), do: false

  defp boundary_vendor(%Edge{target: target} = edge) do
    {vendor, category} = target |> host_of() |> host_vendor()
    element(vendor, category, %{type: "http_boundary", value: boundary_value(edge)})
  end

  defp boundary_value(%Edge{target: target}) when is_binary(target) and target != "", do: target
  defp boundary_value(%Edge{builder: builder}), do: Edge.canonical_builder(builder)

  defp host_of(nil), do: nil

  defp host_of(target) when is_binary(target) do
    case URI.parse(target) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> target |> String.trim() |> strip_path()
    end
  end

  defp host_of(_target), do: nil

  defp strip_path(value) do
    value |> String.split("/", parts: 2) |> hd()
  end

  defp host_vendor(nil), do: {"unknown", nil}

  defp host_vendor(host) do
    normalized = String.downcase(host)

    cond do
      Map.has_key?(@host_vendors, normalized) -> Map.fetch!(@host_vendors, normalized)
      match = domain_match(normalized) -> match
      true -> {vendor_from_host(normalized), nil}
    end
  end

  defp domain_match(host) do
    Enum.find_value(@domain_vendors, fn {domain, vendor} ->
      if host == domain or String.ends_with?(host, "." <> domain), do: vendor
    end)
  end

  defp vendor_from_host(host) do
    host
    |> String.replace_prefix("www.", "")
    |> String.replace_prefix("api.", "")
  end

  # --- elements + merging -------------------------------------------------

  defp element(vendor, category, evidence) do
    %{
      id: "external:" <> slug(vendor),
      vendor: vendor,
      source: "collected",
      evidence: [evidence]
    }
    |> maybe_put(:category, category)
  end

  defp slug(vendor) do
    vendor
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp merge_by_id(elements) do
    elements
    |> Enum.reduce(%{}, fn element, acc ->
      Map.update(acc, element.id, element, &merge_elements(&1, element))
    end)
    |> Map.values()
  end

  defp merge_elements(existing, incoming) do
    existing
    |> Map.put(:evidence, merge_evidence(existing.evidence, incoming.evidence))
    |> maybe_put(:category, existing[:category] || incoming[:category])
  end

  defp merge_evidence(a, b) do
    (a ++ b)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.type, &1.value})
  end

  defp name(module), do: Edge.module_name(module)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
