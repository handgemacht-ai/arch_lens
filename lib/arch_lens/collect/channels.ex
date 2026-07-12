defmodule ArchLens.Collect.Channels do
  @moduledoc """
  Collects Phoenix channel entry points: each user socket's declared channels.

  `collect/1` is the host-app seam: given an `:endpoint` (a Phoenix endpoint
  module) it reflects the socket mounts the endpoint declares (`__sockets__/0`),
  or a caller may pass an explicit `:sockets` list of `{mount_path, socket_module}`.
  Each user socket's channels are read through a guarded `__channels__/0` accessor;
  the framework LiveView socket (`Phoenix.LiveView.Socket`, already surfaced as
  browser routes) and the dev-only `Phoenix.LiveReloader.Socket` are excluded.

  This is a *designed-but-empty* seam in practice: the stable Phoenix socket API
  exposes `__channel__/1` (a per-topic lookup), not a `__channels__/0` list, so the
  guard falls through to `[]` on today's Phoenix — and none of the apps declare user
  channels. `from_sockets/1` is the pure core so the extraction is testable against
  a socket that does expose the list, keeping the seam correct for when channels
  appear (or a Phoenix version surfaces the accessor).

  Every element carries a stable `channel:<topic>:<Channel>` id, `kind: :channel`,
  `source: :collected`, the socket `path`, the `topic` pattern, the channel module
  as `handler`, and a `basis` recording the mount + topic it came from.
  """

  alias ArchLens.Edge

  @excluded_sockets [Phoenix.LiveView.Socket, Phoenix.LiveReloader.Socket]

  @doc """
  Channel entry-point elements for the app's sockets.

  Reads `:sockets` (an explicit `[{mount, socket_module}]` list) when given, else
  reflects `:endpoint.__sockets__/0`. Returns `[]` when neither is available.
  """
  @spec collect(keyword()) :: [map()]
  def collect(opts \\ []) do
    opts |> sockets() |> from_sockets()
  end

  @doc """
  Fold `{mount_path, socket_module}` pairs into sorted channel entry-point elements.

  Pure: `collect/1` is this applied to the reflected/explicit socket list. Framework
  and dev-only sockets are dropped; a socket without a readable `__channels__/0`
  contributes nothing.
  """
  @spec from_sockets([{String.t(), module()}]) :: [map()]
  def from_sockets(sockets) do
    sockets
    |> Enum.reject(fn {_mount, socket} -> socket in @excluded_sockets end)
    |> Enum.flat_map(fn {mount, socket} -> channel_entries(mount, socket) end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp sockets(opts) do
    cond do
      Keyword.has_key?(opts, :sockets) -> Keyword.get(opts, :sockets, [])
      endpoint = Keyword.get(opts, :endpoint) -> endpoint_sockets(endpoint)
      true -> []
    end
  end

  defp endpoint_sockets(endpoint) do
    if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :__sockets__, 0) do
      endpoint.__sockets__()
      |> Enum.map(&normalize_mount/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp normalize_mount({path, socket, _opts}) when is_binary(path) and is_atom(socket),
    do: {path, socket}

  defp normalize_mount({path, socket}) when is_binary(path) and is_atom(socket),
    do: {path, socket}

  defp normalize_mount(_mount), do: nil

  defp channel_entries(mount, socket) do
    if Code.ensure_loaded?(socket) and function_exported?(socket, :__channels__, 0) do
      socket.__channels__() |> Enum.flat_map(&channel_entry(mount, &1))
    else
      []
    end
  end

  defp channel_entry(mount, {topic, {channel, _opts}})
       when is_binary(topic) and is_atom(channel),
       do: [element(mount, topic, channel)]

  defp channel_entry(mount, {topic, channel}) when is_binary(topic) and is_atom(channel),
    do: [element(mount, topic, channel)]

  defp channel_entry(_mount, _channel), do: []

  defp element(mount, topic, channel) do
    handler = Edge.module_name(channel)

    %{
      id: "channel:" <> topic <> ":" <> handler,
      kind: :channel,
      source: :collected,
      path: mount,
      topic: topic,
      handler: handler,
      basis: "socket " <> mount <> " channel " <> topic
    }
  end
end
