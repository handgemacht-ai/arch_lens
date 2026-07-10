defmodule ArchLens.Facade.PubSub do
  @moduledoc """
  Thin facades over `Phoenix.PubSub.broadcast/3,4` and
  `Phoenix.PubSub.subscribe/2,3`.

  Each macro emits exactly the raw `Phoenix.PubSub` call — the same topic
  expression and the same message expression the caller wrote, unquoted verbatim
  — so the topic string and payload that reach PubSub are byte-identical to a hand
  written call. The only added behaviour is compile-time: one `:topic`
  `ArchLens.Edge` is recorded, keyed by `{builder, call_site}`, where the builder
  is inferred from the topic expression (e.g. `Demo.Topics.org(org_id)` yields the
  builder `{Demo.Topics, :org, 1}`) and the call site is where the macro was used.

  The enclosing module must `use ArchLens.Facade` so the edge can be collected.

      defmodule Demo.Events do
        use ArchLens.Facade

        def announce(org_id, payload) do
          broadcast(Demo.PubSub, Demo.Topics.org(org_id), {:announced, payload})
        end
      end
  """

  alias ArchLens.Edge
  alias ArchLens.Facade
  alias ArchLens.Facade.Builder

  @doc "Facade over `Phoenix.PubSub.broadcast/3`."
  defmacro broadcast(pubsub, topic, message) do
    put_topic_edge(__CALLER__, topic)

    quote do
      Phoenix.PubSub.broadcast(unquote(pubsub), unquote(topic), unquote(message))
    end
  end

  @doc "Facade over `Phoenix.PubSub.broadcast/4` (explicit dispatcher)."
  defmacro broadcast(pubsub, topic, message, dispatcher) do
    put_topic_edge(__CALLER__, topic)

    quote do
      Phoenix.PubSub.broadcast(
        unquote(pubsub),
        unquote(topic),
        unquote(message),
        unquote(dispatcher)
      )
    end
  end

  @doc "Facade over `Phoenix.PubSub.subscribe/2`."
  defmacro subscribe(pubsub, topic) do
    put_topic_edge(__CALLER__, topic)

    quote do
      Phoenix.PubSub.subscribe(unquote(pubsub), unquote(topic))
    end
  end

  @doc "Facade over `Phoenix.PubSub.subscribe/3`."
  defmacro subscribe(pubsub, topic, opts) do
    put_topic_edge(__CALLER__, topic)

    quote do
      Phoenix.PubSub.subscribe(unquote(pubsub), unquote(topic), unquote(opts))
    end
  end

  defp put_topic_edge(caller, topic_ast) do
    Facade.put_edge(caller.module, %Edge{
      kind: :topic,
      builder: Builder.from_call(topic_ast, caller),
      call_sites: [{caller.file, caller.line}],
      target: Macro.to_string(topic_ast)
    })
  end
end
