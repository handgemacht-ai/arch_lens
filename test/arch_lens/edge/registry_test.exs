defmodule ArchLens.Edge.RegistryTest do
  # async: false — the registry is a single named process shared across tests.
  use ExUnit.Case, async: false

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry

  setup do
    Registry.reset()
    :ok
  end

  test "registers and enumerates an edge, keyed by its semantic identity" do
    edge = %Edge{
      kind: :topic,
      builder: Some.Topics,
      call_sites: [{"lib/some/resource.ex", 12}],
      target: "some:updated"
    }

    assert {:ok, registered} = Registry.register(edge)
    assert registered == edge
    assert Registry.count() == 1
    assert Registry.all() == [edge]
    assert Registry.key(edge) == {:topic, "Some.Topics", "some:updated"}
    assert Registry.fetch({:topic, "Some.Topics", "some:updated"}) == {:ok, edge}
    assert Registry.fetch(edge) == {:ok, edge}
  end

  test "same-identity call sites collapse into one edge with a merged, sorted call_sites list" do
    Registry.register(%Edge{
      kind: :oban_insert,
      builder: {Some.Worker, :new, 1},
      call_sites: [{"lib/b.ex", 20}],
      target: "Some.Worker.new(args)",
      metadata: %{queue: :default}
    })

    assert {:ok, merged} =
             Registry.register(%Edge{
               kind: :oban_insert,
               builder: {Some.Worker, :new, 1},
               call_sites: [{"lib/a.ex", 10}],
               target: "Some.Worker.new(args)",
               metadata: %{priority: 1}
             })

    assert Registry.count() == 1
    assert merged.call_sites == [{"lib/a.ex", 10}, {"lib/b.ex", 20}]
    assert merged.metadata == %{queue: :default, priority: 1}
  end

  test "re-registering the exact same call site does not duplicate it" do
    edge = %Edge{
      kind: :topic,
      builder: Some.Topics,
      call_sites: [{"lib/some/resource.ex", 12}],
      target: "some:updated"
    }

    Registry.register(edge)
    {:ok, merged} = Registry.register(edge)

    assert Registry.count() == 1
    assert merged.call_sites == [{"lib/some/resource.ex", 12}]
  end

  test "different targets on the same builder are distinct edges" do
    Registry.register(%Edge{kind: :topic, builder: Some.Topics, target: "one", call_sites: []})
    Registry.register(%Edge{kind: :topic, builder: Some.Topics, target: "two", call_sites: []})

    assert Registry.count() == 2
  end

  test "all/0 returns edges in a stable, deterministic order" do
    Registry.register(%Edge{kind: :topic, builder: Zeta, call_sites: [], target: "z"})
    Registry.register(%Edge{kind: :topic, builder: Alpha, call_sites: [], target: "a"})

    assert Enum.map(Registry.all(), & &1.target) == ["a", "z"]
  end

  test "an unknown edge kind is rejected" do
    assert_raise ArgumentError, fn ->
      Registry.register(%Edge{kind: :nonsense, builder: Some.Topics, call_sites: []})
    end
  end

  test "oban_available?/0 returns a boolean without hard-requiring Oban" do
    assert is_boolean(Registry.oban_available?())
  end
end
