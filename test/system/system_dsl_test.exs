defmodule ArchLens.SystemDslFixtures.App do
  @moduledoc false
  use ArchLens.System

  architecture do
    actor(:developer, uses: [:browser, :api, :mcp], does: "captures annotations")
    actor(:ci, uses: [:api], does: "posts build status")
    external(:stripe, via: :http, target: "https://api.stripe.com", does: "billing")
    external(:otel, via: :otlp, target: "http://collector:4317", does: "traces")
    context(:accounts, does: "users and workspaces", modules: "MyApp.Accounts")
    context(:annotations, does: "annotation storage")
  end
end

defmodule ArchLens.SystemDslTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ArchLens.System.{Actor, Context, External, Info}
  alias ArchLens.SystemDslFixtures.App

  describe "Info reads the declared entities back" do
    test "actors are read and sorted by name" do
      actors = Info.actors(App)

      assert Enum.map(actors, & &1.name) == [:ci, :developer]
      assert Enum.all?(actors, &match?(%Actor{}, &1))

      developer = Enum.find(actors, &(&1.name == :developer))
      assert developer.uses == [:browser, :api, :mcp]
      assert developer.does == "captures annotations"
    end

    test "externals are read and sorted deterministically" do
      externals = Info.externals(App)

      assert Enum.all?(externals, &match?(%External{}, &1))

      stripe = Enum.find(externals, &(&1.name == :stripe))
      assert stripe.via == :http
      assert stripe.target == "https://api.stripe.com"
      assert stripe.does == "billing"
    end

    test "contexts are read; modules is optional" do
      contexts = Info.contexts(App)

      assert Enum.map(contexts, & &1.name) == [:accounts, :annotations]
      assert Enum.all?(contexts, &match?(%Context{}, &1))

      assert Enum.find(contexts, &(&1.name == :accounts)).modules == "MyApp.Accounts"
      assert Enum.find(contexts, &(&1.name == :annotations)).modules == nil
    end

    test "architecture/1 groups all three kinds" do
      arch = Info.architecture(App)

      assert Enum.map(arch.actors, & &1.name) == [:ci, :developer]
      assert length(arch.externals) == 2
      assert length(arch.contexts) == 2
    end
  end

  describe "a module that does not use the DSL" do
    test "reads back empty" do
      assert Info.actors(Enum) == []
      assert Info.externals(Enum) == []
      assert Info.contexts(Enum) == []
    end
  end

  describe "compile-time schema enforcement" do
    test "an unknown external via is rejected" do
      code = """
      defmodule ArchLens.SystemDslTest.BadViaFixture do
        use ArchLens.System

        architecture do
          external :thing, via: :carrier_pigeon, target: "x", does: "y"
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/via/, fn ->
          Code.compile_string(code)
        end
      end)
    end

    test "a missing required field is rejected" do
      code = """
      defmodule ArchLens.SystemDslTest.MissingDoesFixture do
        use ArchLens.System

        architecture do
          actor :dev
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/does/, fn ->
          Code.compile_string(code)
        end
      end)
    end

    test "two entities of the same kind under the same name are rejected" do
      code = """
      defmodule ArchLens.SystemDslTest.DuplicateFixture do
        use ArchLens.System

        architecture do
          actor :dev, does: "a"
          actor :dev, does: "b"
        end
      end
      """

      capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/duplicate actor/, fn ->
          Code.compile_string(code)
        end
      end)
    end
  end
end
