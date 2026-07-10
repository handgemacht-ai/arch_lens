defmodule ArchLens.Facade.Topic do
  @moduledoc """
  Declare a named topic family once, then reuse it at every broadcast/subscribe.

  A topic builder is an ordinary public function; `deftopic/2` only exists so the
  intent ("this function names a PubSub topic family") is explicit and so the
  builder can be referenced by name from `ArchLens.Facade.PubSub` call sites,
  which key their edge on `{builder, call_site}`.

      defmodule Demo.Topics do
        use ArchLens.Facade.Topic

        deftopic org(org_id) do
          "demo:" <> org_id
        end
      end

      Demo.Topics.org("acme") #=> "demo:acme"

  The generated function is a plain `def`: the topic string it returns is exactly
  the string its body produces, so a broadcast that reuses it passes the very same
  bytes a raw call would have.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchLens.Facade.Topic, only: [deftopic: 2]
    end
  end

  @doc """
  Define a topic builder `call` whose body returns the topic string.

  `call` is a function head (e.g. `org(org_id)`) and the `do` block is its body;
  the macro emits the matching `def`.
  """
  defmacro deftopic(call, do: body) do
    quote do
      def unquote(call), do: unquote(body)
    end
  end
end
