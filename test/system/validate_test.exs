defmodule ArchLens.System.ValidateTest do
  use ExUnit.Case, async: true

  alias ArchLens.System.Validate

  defp actor(name, uses), do: %{name: name, uses: uses, does: "x", source: "declared"}

  defp external(name, target),
    do: %{name: name, via: :http, target: target, does: "x", source: "declared"}

  defp context(name, modules),
    do: %{name: name, does: "x", modules: modules, source: "declared"}

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
    test "passes when the target matches a collected external system" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      ctx = Validate.context(%{external_systems: [%{target: "https://api.stripe.com/"}]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "passes when the name matches a dependency vendor" do
      declared = declared(externals: [external(:req, "https://example.test")])
      ctx = Validate.context(%{external_systems: [%{target: "https://other"}], vendors: [:req]})

      assert {:ok, []} = Validate.validate(declared, ctx)
    end

    test "fails when it matches neither a collected system nor a vendor" do
      declared = declared(externals: [external(:stripe, "https://api.stripe.com")])
      ctx = Validate.context(%{external_systems: [%{target: "https://other"}]})

      assert {:error, [message]} = Validate.validate(declared, ctx)
      assert message =~ "external :stripe"
      assert message =~ "https://api.stripe.com"
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
          external_systems: [%{target: "https://other"}],
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
