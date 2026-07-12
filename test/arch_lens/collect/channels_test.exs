defmodule ArchLens.Collect.ChannelsTest do
  # async: false — reflects module-level accessors, keep serialized for determinism.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Channels
  alias ArchLens.Generator.Sections.EntryPoints

  defmodule RoomChannel do
    @moduledoc false
  end

  defmodule LobbyChannel do
    @moduledoc false
  end

  # A user socket that exposes a `__channels__/0` list (the shape the collector
  # reads). Both `{topic, {channel, opts}}` and `{topic, channel}` tuple forms are
  # covered.
  defmodule UserSocket do
    @moduledoc false
    def __channels__ do
      [
        {"room:*", {RoomChannel, []}},
        {"lobby", LobbyChannel}
      ]
    end
  end

  # A socket that does not expose the list accessor — the real-Phoenix shape (only
  # `__channel__/1`). The collector must skip it, not crash.
  defmodule LookupOnlySocket do
    @moduledoc false
    def __channel__(_topic), do: nil
  end

  defmodule FakeEndpoint do
    @moduledoc false
    def __sockets__, do: [{"/socket", ArchLens.Collect.ChannelsTest.UserSocket, []}]
  end

  defmodule LiveViewEndpoint do
    @moduledoc false
    def __sockets__ do
      [
        {"/live", Phoenix.LiveView.Socket, []},
        {"/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket, []}
      ]
    end
  end

  describe "from_sockets/1 — pure extraction" do
    test "folds each socket's channels into sorted :channel elements" do
      [lobby, room] = Channels.from_sockets([{"/socket", UserSocket}])

      assert room.id == "channel:room:*:ArchLens.Collect.ChannelsTest.RoomChannel"
      assert room.kind == :channel
      assert room.source == :collected
      assert room.path == "/socket"
      assert room.topic == "room:*"
      assert room.handler == "ArchLens.Collect.ChannelsTest.RoomChannel"
      assert room.basis == "socket /socket channel room:*"

      assert lobby.topic == "lobby"
      assert lobby.handler == "ArchLens.Collect.ChannelsTest.LobbyChannel"
    end

    test "the framework LiveView and dev live-reload sockets are excluded" do
      assert Channels.from_sockets([
               {"/live", Phoenix.LiveView.Socket},
               {"/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket}
             ]) == []
    end

    test "a socket without a __channels__/0 accessor contributes nothing" do
      assert Channels.from_sockets([{"/socket", LookupOnlySocket}]) == []
    end

    test "extraction is deterministic" do
      assert Channels.from_sockets([{"/socket", UserSocket}]) ==
               Channels.from_sockets([{"/socket", UserSocket}])
    end
  end

  describe "collect/1 — host-app seam" do
    test "an explicit :sockets list is read directly" do
      elements = Channels.collect(sockets: [{"/socket", UserSocket}])
      assert Enum.map(elements, & &1.topic) == ["lobby", "room:*"]
    end

    test "an :endpoint's socket mounts are reflected via __sockets__/0" do
      elements = Channels.collect(endpoint: FakeEndpoint)
      assert Enum.map(elements, & &1.topic) == ["lobby", "room:*"]
      assert Enum.all?(elements, &(&1.path == "/socket"))
    end

    test "reflected framework sockets yield no channel entries" do
      assert Channels.collect(endpoint: LiveViewEndpoint) == []
    end

    test "no :sockets and no :endpoint yields []" do
      assert Channels.collect([]) == []
    end
  end

  describe "rendering :channel entries in the entry-points section" do
    test "a channel entry renders under a Channel group with its topic and handler" do
      markdown =
        [{"/socket", UserSocket}]
        |> Channels.from_sockets()
        |> EntryPoints.to_json()
        |> EntryPoints.render()
        |> Enum.join("\n")

      assert markdown =~ "### Channel (2)"

      assert markdown =~
               "- `room:*` → ArchLens.Collect.ChannelsTest.RoomChannel — _Unattributed · socket /socket channel room:*_"
    end
  end
end
