defmodule ArchLens.Edge.RegistryTest do
  # async: false — the registry is a single named process shared across tests.
  use ExUnit.Case, async: false

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry

  setup do
    Registry.reset()
    :ok
  end

  test "registers and enumerates an edge keyed by {builder, call_site}" do
    edge = %Edge{
      kind: :topic,
      builder: Some.Topics,
      call_site: {Some.Resource, "lib/some/resource.ex", 12},
      target: "some:updated"
    }

    assert {:ok, ^edge} = Registry.register(edge)
    assert Registry.count() == 1
    assert Registry.all() == [edge]
    assert Registry.fetch(Some.Topics, {Some.Resource, "lib/some/resource.ex", 12}) == {:ok, edge}
  end

  test "register/3 builds an edge from builder, call_site and attrs" do
    assert {:ok, edge} =
             Registry.register(Some.Workers, {Some.Resource, :enqueue, 1},
               kind: :oban_insert,
               target: Some.Worker
             )

    assert edge.kind == :oban_insert
    assert edge.builder == Some.Workers
    assert edge.call_site == {Some.Resource, :enqueue, 1}
    assert edge.target == Some.Worker
    assert Registry.count() == 1
  end

  test "re-registering the same {builder, call_site} replaces rather than duplicates" do
    call_site = {Some.Resource, "lib/some/resource.ex", 12}

    Registry.register(%Edge{
      kind: :topic,
      builder: Some.Topics,
      call_site: call_site,
      target: "one"
    })

    Registry.register(%Edge{
      kind: :topic,
      builder: Some.Topics,
      call_site: call_site,
      target: "two"
    })

    assert Registry.count() == 1
    assert [%Edge{target: "two"}] = Registry.all()
  end

  test "all/0 returns edges in a stable, deterministic order" do
    Registry.register(%Edge{kind: :http_boundary, builder: Zeta, call_site: 2, target: "z"})
    Registry.register(%Edge{kind: :topic, builder: Alpha, call_site: 1, target: "a"})

    assert Enum.map(Registry.all(), & &1.target) == ["a", "z"]
  end

  test "an unknown edge kind is rejected" do
    assert_raise ArgumentError, fn ->
      Registry.register(%Edge{kind: :nonsense, builder: Some.Topics, call_site: 1})
    end
  end

  test "oban_available?/0 returns a boolean without hard-requiring Oban" do
    assert is_boolean(Registry.oban_available?())
  end
end
