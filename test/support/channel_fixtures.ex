defmodule ArchLens.ChannelFixtures do
  @moduledoc """
  A real Phoenix socket + channels for `ArchLens.Collect.Channels`.

  This file holds a single `use Phoenix.Socket` module so the collector's
  module → compiled-source → AST path can be exercised end-to-end: reading
  `UserSocket.__info__(:compile)[:source]` yields *this* file, whose only `channel`
  declarations belong to `UserSocket`. One handler is referenced fully-qualified and
  one through an `alias`, so the source scan's alias resolution is covered against
  genuinely compiled code, not just inline source strings.
  """
end

defmodule ArchLens.ChannelFixtures.RoomChannel do
  @moduledoc false
  use Phoenix.Channel

  @impl true
  def join(_topic, _payload, socket), do: {:ok, socket}
end

defmodule ArchLens.ChannelFixtures.LobbyChannel do
  @moduledoc false
  use Phoenix.Channel

  @impl true
  def join(_topic, _payload, socket), do: {:ok, socket}
end

defmodule ArchLens.ChannelFixtures.UserSocket do
  @moduledoc false
  use Phoenix.Socket

  alias ArchLens.ChannelFixtures.LobbyChannel

  channel("room:*", ArchLens.ChannelFixtures.RoomChannel)
  channel("lobby", LobbyChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule ArchLens.ChannelFixtures.FakeEndpoint do
  @moduledoc false
  def __sockets__, do: [{"/socket", ArchLens.ChannelFixtures.UserSocket, []}]
end

defmodule ArchLens.ChannelFixtures.LiveViewEndpoint do
  @moduledoc false
  def __sockets__ do
    [
      {"/live", Phoenix.LiveView.Socket, []},
      {"/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket, []}
    ]
  end
end
