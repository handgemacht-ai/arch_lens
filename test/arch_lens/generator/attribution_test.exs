defmodule ArchLens.Generator.AttributionTest do
  # async: false — compiles annotated fixture modules read back via introspection.
  use ExUnit.Case, async: false

  alias ArchLens.Generator.Attribution
  alias ArchLens.Generator.Sections.EntryPoints

  # An Ash.Domain context that declares the web namespaces it serves (exercises the
  # `ArchLens.Domain.interface/1` reader).
  defmodule Accounts do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false, extensions: [ArchLens.Domain]

    architecture do
      does("accounts")
      interface(["MyAppWeb.AccountController", "MyAppWeb.Admin"])
    end

    resources do
    end
  end

  # A plain context module with no interface — only namespace containment can
  # attribute handlers under it.
  defmodule Workers do
    @moduledoc false
    use ArchLens.Context, does: "background jobs", name: :workers
  end

  # A plain context module that claims a handler *inside* the Workers namespace via
  # an interface, so interface-vs-containment precedence is observable (exercises the
  # `ArchLens.Context.Info.interface/1` reader).
  defmodule Reports do
    @moduledoc false
    use ArchLens.Context,
      does: "reporting",
      name: :reports,
      interface: ["ArchLens.Generator.AttributionTest.Workers.Special"]
  end

  defp accounts_ctx, do: %{name: :accounts, module: Accounts, origin: :domain}
  defp workers_ctx, do: %{name: :workers, module: Workers, origin: :context_module}
  defp reports_ctx, do: %{name: :reports, module: Reports, origin: :context_module}

  defp contexts, do: [accounts_ctx(), workers_ctx(), reports_ctx()]

  defp entry(handler), do: %{id: "route:GET:/x", kind: :browser, handler: handler}

  defp attribute_one(handler, contexts \\ nil) do
    [element] = Attribution.attribute([entry(handler)], contexts || contexts())
    element
  end

  describe "declared interface attribution" do
    test "an exact interface match attributes the handler to the declaring context" do
      element = attribute_one("MyAppWeb.AccountController")
      assert element.context == "accounts"
      assert element.context_basis == "declared by context accounts"
    end

    test "a handler nested under a declared interface namespace is attributed" do
      element = attribute_one("MyAppWeb.Admin.DashboardController")
      assert element.context == "accounts"
      assert element.context_basis == "declared by context accounts"
    end

    test "a handler that only shares a name prefix (not a namespace) is not attributed" do
      element = attribute_one("MyAppWeb.AccountControllerExtra")
      assert element.context == nil
      refute Map.has_key?(element, :context_basis)
    end
  end

  describe "namespace containment attribution" do
    test "a handler under a context's root module is attributed by containment" do
      element = attribute_one("ArchLens.Generator.AttributionTest.Workers.GuestCleanup")
      assert element.context == "workers"

      assert element.context_basis ==
               "namespace containment (ArchLens.Generator.AttributionTest.Workers)"
    end

    test "a handler equal to the context's root module is attributed" do
      element = attribute_one("ArchLens.Generator.AttributionTest.Workers")
      assert element.context == "workers"
    end

    test "the longest containing prefix wins" do
      contexts = [
        %{name: :outer, module: Some.Deep, origin: :context_module},
        %{name: :inner, module: Some.Deep.Nested, origin: :context_module}
      ]

      element = attribute_one("Some.Deep.Nested.Handler", contexts)
      assert element.context == "inner"
    end
  end

  describe "precedence and honest fallback" do
    test "a declared interface wins over namespace containment" do
      element = attribute_one("ArchLens.Generator.AttributionTest.Workers.Special")
      assert element.context == "reports"
      assert element.context_basis == "declared by context reports"
    end

    test "an unmatched handler is left unattributed (context nil, no basis)" do
      element = attribute_one("SomeWeb.RandomController")
      assert element.context == nil
      refute Map.has_key?(element, :context_basis)
    end

    test "a central-declared context (no module) never attributes" do
      element =
        attribute_one("MyAppWeb.AccountController", [%{name: :legacy, origin: :central_declared}])

      assert element.context == nil
    end

    test "an entry without a handler passes through untouched" do
      passthrough = %{label: "GET /health"}
      assert Attribution.attribute([passthrough], contexts()) == [passthrough]
    end

    test "attribution is deterministic" do
      entries = [entry("MyAppWeb.AccountController"), entry("SomeWeb.RandomController")]

      assert Attribution.attribute(entries, contexts()) ==
               Attribution.attribute(entries, contexts())
    end
  end

  describe "rendering the attributed context inline" do
    test "the context and classification basis render in each bullet, else Unattributed" do
      entries = [
        %{
          id: "route:GET:/acct",
          kind: :browser,
          method: "GET",
          path: "/acct",
          handler: "MyAppWeb.AccountController",
          basis: "accepts html"
        },
        %{
          id: "route:GET:/misc",
          kind: :browser,
          method: "GET",
          path: "/misc",
          handler: "SomeWeb.RandomController",
          basis: "accepts html"
        }
      ]

      markdown =
        entries
        |> Attribution.attribute(contexts())
        |> EntryPoints.to_json()
        |> EntryPoints.render()
        |> Enum.join("\n")

      assert markdown =~ "- `GET /acct` → MyAppWeb.AccountController — _accounts · accepts html_"

      assert markdown =~
               "- `GET /misc` → SomeWeb.RandomController — _Unattributed · accepts html_"
    end
  end
end
