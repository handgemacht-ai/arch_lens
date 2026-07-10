defmodule ArchLensPubSubDemo.Topics do
  @moduledoc false
  use ArchLens.Facade.Topic

  deftopic org(org_id) do
    "demo:" <> org_id
  end
end

defmodule ArchLensPubSubDemo.Events do
  @moduledoc false
  use ArchLens.Facade

  alias ArchLensPubSubDemo.Topics

  def announce(pubsub, org_id, payload) do
    broadcast(pubsub, Topics.org(org_id), {:announced, payload})
  end

  def listen(pubsub, org_id) do
    subscribe(pubsub, Topics.org(org_id))
  end
end

defmodule ArchLens.Facade.PubSubFacadeTest do
  # async: false — the edge registry is a single named process shared across tests.
  use ExUnit.Case, async: false

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry
  alias ArchLens.Facade
  alias ArchLensPubSubDemo.Events
  alias ArchLensPubSubDemo.Topics

  @pubsub ArchLensPubSubDemo.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    Registry.reset()
    :ok
  end

  test "facade broadcast produces the exact topic string and payload tuple of a raw call" do
    org_id = "acme"
    built_topic = Topics.org(org_id)
    assert built_topic == "demo:acme"

    :ok = Phoenix.PubSub.subscribe(@pubsub, built_topic)
    payload = %{n: 1}

    # Facade broadcast — subscribed to the builder's topic, so delivery proves the
    # facade used the exact same topic string.
    assert :ok = Events.announce(@pubsub, org_id, payload)
    assert_receive facade_message

    # The equivalent raw call, byte-for-byte.
    assert :ok = Phoenix.PubSub.broadcast(@pubsub, built_topic, {:announced, payload})
    assert_receive raw_message

    assert facade_message == raw_message
    assert facade_message == {:announced, %{n: 1}}
  end

  test "facade subscribe subscribes to the exact topic a raw subscribe would" do
    assert :ok = Events.listen(@pubsub, "acme")

    Phoenix.PubSub.broadcast(@pubsub, "demo:acme", {:hello, 1})
    assert_receive {:hello, 1}
  end

  test "a topic edge is registered keyed by {builder, call_site} for each facade call site" do
    edges = Facade.register_edges(Events)

    assert length(edges) == 2
    assert Enum.all?(edges, &(&1.kind == :topic))
    assert Enum.all?(edges, &(&1.builder == {Topics, :org, 1}))

    for %Edge{} = edge <- edges do
      assert {Events, file, line} = edge.call_site
      assert is_binary(file) and is_integer(line)
      assert Registry.fetch(edge.builder, edge.call_site) == {:ok, edge}
    end

    assert MapSet.new(Registry.all()) == MapSet.new(edges)
  end
end
