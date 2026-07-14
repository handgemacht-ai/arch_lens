defmodule ArchLens.Collect.ChannelsTest do
  # async: false — the seam tests read compiled modules' source files; keep
  # serialized for determinism alongside the other collector tests.
  use ExUnit.Case, async: false

  alias ArchLens.Collect.Channels
  alias ArchLens.Generator.Sections.EntryPoints

  # A socket source that references one handler fully-qualified and one through an
  # alias, covering both resolution paths, plus a wildcard and a bare topic.
  @socket_source """
  defmodule MyAppWeb.UserSocket do
    use Phoenix.Socket

    alias MyAppWeb.Channels.LobbyChannel

    channel "room:*", MyAppWeb.Channels.RoomChannel
    channel "lobby", LobbyChannel
  end
  """

  describe "from_sources/1 — pure extraction from socket source" do
    test "folds each channel into a sorted :channel element, resolving the handler" do
      [lobby, room] = Channels.from_sources([{"/socket", @socket_source}])

      assert room.id == "channel:room:*:MyAppWeb.Channels.RoomChannel"
      assert room.kind == :channel
      assert room.source == :collected
      assert room.path == "/socket"
      assert room.topic == "room:*"
      assert room.handler == "MyAppWeb.Channels.RoomChannel"
      assert room.basis == "socket /socket channel room:*"

      assert lobby.topic == "lobby"
      assert lobby.handler == "MyAppWeb.Channels.LobbyChannel"
    end

    test "resolves a handler declared with `alias ..., as:`" do
      source = """
      defmodule Sock do
        use Phoenix.Socket
        alias MyApp.Realtime.NotificationsChannel, as: Notify
        channel "notify:*", Notify
      end
      """

      [entry] = Channels.from_sources([{"/socket", source}])
      assert entry.handler == "MyApp.Realtime.NotificationsChannel"
    end

    test "resolves a handler declared with a multi-alias `{}` group" do
      source = """
      defmodule Sock do
        use Phoenix.Socket
        alias MyApp.Channels.{RoomChannel, LobbyChannel}
        channel "room:*", RoomChannel
        channel "lobby", LobbyChannel
      end
      """

      handlers = Channels.from_sources([{"/socket", source}]) |> Enum.map(& &1.handler)
      assert "MyApp.Channels.RoomChannel" in handlers
      assert "MyApp.Channels.LobbyChannel" in handlers
    end

    test "reads a channel/3 declaration (with opts) the same as channel/2" do
      source = """
      defmodule Sock do
        use Phoenix.Socket
        channel "room:*", MyApp.RoomChannel, assigns: %{a: 1}
      end
      """

      [entry] = Channels.from_sources([{"/socket", source}])
      assert entry.topic == "room:*"
      assert entry.handler == "MyApp.RoomChannel"
    end

    test "skips a channel with a non-literal (interpolated) topic" do
      source = """
      defmodule Sock do
        use Phoenix.Socket
        @prefix "room"
        channel "\#{@prefix}:*", MyApp.RoomChannel
      end
      """

      assert Channels.from_sources([{"/socket", source}]) == []
    end

    test "a source that declares no channel contributes nothing" do
      source = """
      defmodule Sock do
        use Phoenix.Socket
        def connect(_p, s, _i), do: {:ok, s}
      end
      """

      assert Channels.from_sources([{"/socket", source}]) == []
    end

    test "a source that fails to parse contributes nothing (no raise)" do
      assert Channels.from_sources([{"/socket", "defmodule Broken do channel "}]) == []
    end

    test "extraction is deterministic" do
      assert Channels.from_sources([{"/socket", @socket_source}]) ==
               Channels.from_sources([{"/socket", @socket_source}])
    end

    test "channels from multiple sockets are de-duplicated by id and sorted" do
      other = """
      defmodule Other do
        use Phoenix.Socket
        channel "admin:*", MyApp.AdminChannel
      end
      """

      topics =
        Channels.from_sources([{"/socket", @socket_source}, {"/admin", other}])
        |> Enum.map(& &1.topic)

      assert topics == ["admin:*", "lobby", "room:*"]
    end
  end

  describe "collect/1 — :socket_sources escape hatch" do
    test "reads an explicit [{mount, source}] list directly" do
      elements = Channels.collect(socket_sources: [{"/socket", @socket_source}])
      assert Enum.map(elements, & &1.topic) == ["lobby", "room:*"]
      assert Enum.all?(elements, &(&1.path == "/socket"))
    end

    test "no options yields []" do
      assert Channels.collect([]) == []
    end
  end

  describe "collect/1 — real compiled socket via its source file" do
    test "an explicit :sockets module list reads each socket's compiled source" do
      elements = Channels.collect(sockets: [{"/socket", ArchLens.ChannelFixtures.UserSocket}])

      assert Enum.map(elements, & &1.topic) == ["lobby", "room:*"]

      assert Enum.map(elements, & &1.handler) == [
               "ArchLens.ChannelFixtures.LobbyChannel",
               "ArchLens.ChannelFixtures.RoomChannel"
             ]
    end

    test "an :endpoint's socket mounts are reflected via __sockets__/0 then scanned" do
      elements = Channels.collect(endpoint: ArchLens.ChannelFixtures.FakeEndpoint)
      assert Enum.map(elements, & &1.topic) == ["lobby", "room:*"]
      assert Enum.all?(elements, &(&1.path == "/socket"))
    end

    test "the framework LiveView and dev live-reload sockets are excluded" do
      assert Channels.collect(endpoint: ArchLens.ChannelFixtures.LiveViewEndpoint) == []

      assert Channels.collect(
               sockets: [
                 {"/live", Phoenix.LiveView.Socket},
                 {"/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket}
               ]
             ) == []
    end
  end

  describe "rendering :channel entries in the entry-points section" do
    test "a channel entry renders under a Channel group with its topic and handler" do
      markdown =
        [{"/socket", @socket_source}]
        |> Channels.from_sources()
        |> EntryPoints.to_json()
        |> EntryPoints.render()
        |> Enum.join("\n")

      assert markdown =~ "### Channel (2)"

      assert markdown =~
               "- `room:*` → MyAppWeb.Channels.RoomChannel — _Unattributed · socket /socket channel room:*_"
    end
  end
end
