defmodule ArchLens.Collect.Channels do
  @moduledoc """
  Collects Phoenix channel entry points by scanning socket source.

  A socket declares its channels with the `channel "topic", Handler` macro, which
  Phoenix folds into a private `__channel__/1` topic-lookup at compile time — there
  is *no* runtime list of a socket's channels (only the per-topic matcher), so the
  channels can only be recovered from source. This collector reads each user
  socket's source file and extracts the `channel` declarations from its AST.

  `collect/1` is the host-app seam and resolves *which* sockets to scan, in order:

    * `:socket_sources` — an explicit `[{mount_path, source_string}]` list (the pure
      escape hatch used by tests and callers that already hold the source).
    * `:sockets` — an explicit `[{mount_path, socket_module}]` list; each module's
      compiled source file is read (`__info__(:compile)[:source]`).
    * `:endpoint` — a Phoenix endpoint module whose declared socket mounts are
      reflected via `__sockets__/0`, then read the same way as `:sockets`.

  The framework LiveView socket (`Phoenix.LiveView.Socket`, already surfaced as
  browser routes) and the dev-only `Phoenix.LiveReloader.Socket` are excluded; a
  socket whose source cannot be read contributes nothing.

  `from_sources/1` is the pure core: it folds `{mount_path, source_string}` pairs
  into the sorted elements, so extraction (channel discovery + handler alias
  resolution) is testable without any compiled socket or file on disk.

  ## Extraction (from the socket's AST)

  Each `channel "topic", Handler` is read straight from the source: the `topic`
  pattern verbatim (only string literals — an interpolated/dynamic topic is skipped
  rather than guessed), and the `Handler` module resolved against the socket's own
  `alias` directives so the recorded handler is the fully-qualified module (which is
  what the namespace attribution keys on). A handler that cannot be resolved to a
  module (e.g. a variable) is skipped. Channels injected by an outer `use`/macro
  (not literally present in the source) are not visible to a source scan.

  Every element carries a stable `channel:<topic>:<Channel>` id, `kind: :channel`,
  `source: :collected`, the socket `path`, the `topic` pattern, the channel module
  as `handler`, and a `basis` recording the mount + topic it came from. Elements are
  de-duplicated by id and sorted by it, so an unchanged socket reproduces
  byte-identical output.
  """

  alias ArchLens.Edge

  @excluded_sockets [Phoenix.LiveView.Socket, Phoenix.LiveReloader.Socket]

  @doc """
  Channel entry-point elements for the app's sockets.

  Resolves the sockets to scan from `:socket_sources`, `:sockets`, or `:endpoint`
  (see the moduledoc), reads their source, and extracts the `channel` declarations.
  Returns `[]` when none of those options are given.
  """
  @spec collect(keyword()) :: [map()]
  def collect(opts \\ []) do
    opts |> socket_sources() |> from_sources()
  end

  @doc """
  Fold `{mount_path, source_string}` pairs into sorted channel entry-point elements.

  Pure: `collect/1` is this applied to the resolved/read socket sources. A source
  that fails to parse, or that declares no `channel`, contributes nothing.
  """
  @spec from_sources([{String.t(), String.t()}]) :: [map()]
  def from_sources(sources) do
    sources
    |> Enum.flat_map(fn {mount, source} -> channel_entries(mount, source) end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  # --- socket resolution -----------------------------------------------------

  defp socket_sources(opts) do
    cond do
      Keyword.has_key?(opts, :socket_sources) ->
        opts |> Keyword.get(:socket_sources, []) |> Enum.filter(&valid_source_pair?/1)

      Keyword.has_key?(opts, :sockets) ->
        opts |> Keyword.get(:sockets, []) |> sockets_to_sources()

      endpoint = Keyword.get(opts, :endpoint) ->
        endpoint |> endpoint_sockets() |> sockets_to_sources()

      true ->
        []
    end
  end

  defp valid_source_pair?({mount, source}) when is_binary(mount) and is_binary(source), do: true
  defp valid_source_pair?(_pair), do: false

  defp sockets_to_sources(sockets) do
    sockets
    |> Enum.reject(fn {_mount, socket} -> socket in @excluded_sockets end)
    |> Enum.flat_map(fn {mount, socket} ->
      case module_source(socket) do
        nil -> []
        source -> [{mount, source}]
      end
    end)
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

  # A loaded module's compiled source file, read to a string. `nil` when the module
  # is not loadable, carries no compiled source, or the file cannot be read — so a
  # socket without recoverable source degrades to no channels rather than raising.
  defp module_source(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         source when is_list(source) or is_binary(source) <-
           module.__info__(:compile)[:source],
         {:ok, contents} <- File.read(to_string(source)) do
      contents
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp module_source(_module), do: nil

  # --- source scanning -------------------------------------------------------

  defp channel_entries(mount, source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)

        ast
        |> collect_channel_calls()
        |> Enum.flat_map(&channel_element(mount, &1, aliases))

      _ ->
        []
    end
  end

  defp channel_entries(_mount, _source), do: []

  # The `%{alias_name => module}` map of the source's `alias` directives, so a
  # channel handler written as an alias resolves to its fully-qualified module.
  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn node, acc -> {node, merge_alias(node, acc)} end)

    aliases
  end

  # alias A.B.C  →  C => A.B.C
  defp merge_alias({:alias, _meta, [{:__aliases__, _, segments}]}, acc) when is_list(segments),
    do: put_alias(acc, segments)

  # alias A.B, as: X  →  X => A.B   (falls back to the last-segment key on a
  # non-literal `as:`)
  defp merge_alias({:alias, _meta, [{:__aliases__, _, segments}, opts]}, acc)
       when is_list(segments) and is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as_name]} when is_atom(as_name) ->
        Map.put(acc, as_name, Module.concat(segments))

      _ ->
        put_alias(acc, segments)
    end
  end

  # alias A.B.{C, D.E}  →  C => A.B.C, E => A.B.D.E
  defp merge_alias({:alias, _meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, acc)
       when is_list(base) and is_list(children) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, child_segments}, inner when is_list(child_segments) ->
        put_alias(inner, base ++ child_segments)

      _child, inner ->
        inner
    end)
  end

  defp merge_alias(_node, acc), do: acc

  defp put_alias(acc, segments) do
    case List.last(segments) do
      key when is_atom(key) -> Map.put(acc, key, Module.concat(segments))
      _ -> acc
    end
  end

  defp collect_channel_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:channel, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp channel_element(mount, [topic, handler | _rest], aliases) when is_binary(topic) do
    case resolve_module(handler, aliases) do
      nil -> []
      module -> [element(mount, topic, module)]
    end
  end

  defp channel_element(_mount, _args, _aliases), do: []

  # Resolve a `channel` handler AST to a fully-qualified module: an alias whose head
  # segment is in scope expands against it, otherwise the segments concatenate as
  # written. A bare module atom passes through; anything else is unresolvable.
  defp resolve_module({:__aliases__, _meta, [head | rest]}, aliases) when is_atom(head) do
    case Map.get(aliases, head) do
      nil -> Module.concat([head | rest])
      base -> Module.concat([base | rest])
    end
  end

  defp resolve_module(module, _aliases) when is_atom(module) and not is_nil(module), do: module

  defp resolve_module(_handler, _aliases), do: nil

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
