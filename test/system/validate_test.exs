defmodule ArchLens.System.ValidateTest do
  use ExUnit.Case, async: true

  alias ArchLens.Collect.Externals
  alias ArchLens.Edge
  alias ArchLens.System.Validate

  defp actor(name, uses), do: %{name: name, uses: uses, does: "x", source: "declared"}

  defp external(name, target),
    do: %{name: name, via: :http, target: target, does: "x", source: "declared"}

  defp context(name, modules),
    do: %{name: name, does: "x", modules: modules, source: "declared"}

  # A real HTTP boundary edge, mined into a collected external system by the actual
  # ArchLens.Collect.Externals — the shape Validate must reconcile against.
  defp boundary(target) do
    %Edge{
      kind: :http_boundary,
      builder: {ArchLens.CollectFixtures.Custom, :call},
      target: target,
      call_sites: [{"lib/x.ex", 1}]
    }
  end

  defp declared(opts) do
    %{
      actors: Keyword.get(opts, :actors, []),
      externals: Keyword.get(opts, :externals, []),
      contexts: Keyword.get(opts, :contexts, [])
    }
  end

  describe "rule (a): actor entry points" do
    test "passes when every used entry point was collected" do
      declared = declared(actors: [actor(:dev, [:api, :browser])])
      ctx = Validate.context(%{entry_points: [%{kind: :api}, %{kind: :browser}]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "passes for vocabulary kinds beyond the original four when collected" do
      declared = declared(actors: [actor(:dev, [:oauth, :other])])
      ctx = Validate.context(%{entry_points: [%{kind: :oauth}, %{kind: :other}]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "fails when an actor claims an uncollected entry point" do
      declared = declared(actors: [actor(:dev, [:api, :webhook])])
      ctx = Validate.context(%{entry_points: [%{kind: :api}]})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "actor :dev"
      assert message =~ ":webhook"
    end

    test "cross-checks every vocabulary kind, not just the original four" do
      declared = declared(actors: [actor(:dev, [:oauth])])
      ctx = Validate.context(%{entry_points: [%{kind: :api}]})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "actor :dev"
      assert message =~ ":oauth"
      assert message =~ "was collected"
    end

    test "rejects an unknown uses: atom when entry points were collected" do
      declared = declared(actors: [actor(:dev, [:api, :telepathy])])
      ctx = Validate.context(%{entry_points: [%{kind: :api}]})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "actor :dev"
      assert message =~ ":telepathy"
      assert message =~ "not a known entry-point kind"
      assert message =~ ":browser"
      # the valid :api use produces no error
      refute message =~ ":api entry point"
    end

    test "rejects an unknown uses: atom even when no entry points were collected" do
      declared = declared(actors: [actor(:dev, [:telepathy])])
      ctx = Validate.context(%{entry_points: []})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "actor :dev"
      assert message =~ ":telepathy"
      assert message =~ "not a known entry-point kind"
    end

    test "skips the collected cross-check with a warning when no entry points were collected" do
      declared = declared(actors: [actor(:dev, [:api])])
      ctx = Validate.context(%{entry_points: []})

      assert {:ok, [warning]} = Validate.validate(declared, ctx)
      assert warning =~ "entry points not collected"
    end
  end

  describe "rule (b): HTTP externals" do
    test "passes when the declared id matches a collected external system (dep evidence)" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      ctx = Validate.context(%{external_systems: Externals.collect(deps: [:stripity_stripe])})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "passes when the declared target host matches a collected HTTP boundary" do
      declared = declared(externals: [external(:acme, "https://api.acme.io")])

      ctx =
        Validate.context(%{
          external_systems: Externals.collect(edges: [boundary("https://api.acme.io")])
        })

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    # Regression (false-REJECT): the real Collect.Externals element carries no
    # :target key — only an id/vendor and evidence — so target-only matching used to
    # reject a truthful declaration outright.
    test "a truthful declared external passes against real Collect.Externals output" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      collected = Externals.collect(deps: [:stripity_stripe])

      refute Enum.any?(collected, &Map.has_key?(&1, :target))

      assert {:ok, []} =
               Validate.validate(declared, Validate.context(%{external_systems: collected}))
    end

    test "fails when it matches neither a collected system id nor a boundary host" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      ctx = Validate.context(%{external_systems: Externals.collect(deps: [:sentry])})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "external :stripe"
      assert message =~ "https://api.stripe.com"
    end

    # Regression (false-ACCEPT): a bare name collision with an arbitrary dependency
    # app in the OTP closure must NOT corroborate egress. `:jason` is a real dep, so
    # the old app-closure vendor match let a fabricated target pass.
    test "a fabricated external is not corroborated by a dependency-app name collision" do
      declared = declared(externals: [external(:jason, "https://fabricated.example")])

      ctx =
        Validate.context(%{
          external_systems: Externals.collect(deps: [:stripity_stripe]),
          vendors: [:jason, :phoenix, :ash]
        })

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "external :jason"
    end

    test "skips with a warning when no external systems were collected" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      ctx = Validate.context(%{external_systems: []})

      assert {:ok, [warning]} = Validate.validate(declared, ctx)
      assert warning =~ "external systems not collected"
    end
  end

  describe "rule (c): context modules" do
    test "passes when the prefix names at least one known module" do
      declared = declared(contexts: [context(:accounts, "MyApp.Accounts")])
      ctx = Validate.context(%{known_modules: ["MyApp.Accounts.User"]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "fails when no known module carries the prefix" do
      declared = declared(contexts: [context(:accounts, "MyApp.Accounts")])
      ctx = Validate.context(%{known_modules: ["MyApp.Billing.Plan"]})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "context :accounts"
      assert message =~ "MyApp.Accounts"
    end

    test "a context without a modules prefix is never checked" do
      declared = declared(contexts: [context(:accounts, nil)])
      ctx = Validate.context(%{known_modules: ["MyApp.Billing.Plan"]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "skips with a warning when no module list is available" do
      declared = declared(contexts: [context(:accounts, "MyApp.Accounts")])
      ctx = Validate.context(%{known_modules: []})

      assert {:ok, [warning]} = Validate.validate(declared, ctx)
      assert warning =~ "module list unavailable"
    end
  end

  describe "all failures are collected at once" do
    test "one result lists every failing check, sorted" do
      declared =
        declared(
          actors: [actor(:dev, [:webhook])],
          externals: [external(:stripe, "https://api.stripe.com")],
          contexts: [context(:accounts, "MyApp.Accounts")]
        )

      ctx =
        Validate.context(%{
          entry_points: [%{kind: :api}],
          external_systems: Externals.collect(deps: [:sentry]),
          known_modules: ["MyApp.Billing.Plan"]
        })

      assert {:error, errors} = Validate.validate(declared, ctx)
      assert length(errors) == 3
      assert Enum.any?(errors, &(&1 =~ "actor :dev"))
      assert Enum.any?(errors, &(&1 =~ "external :stripe"))
      assert Enum.any?(errors, &(&1 =~ "context :accounts"))
      assert errors == Enum.sort(errors)
    end
  end
end
