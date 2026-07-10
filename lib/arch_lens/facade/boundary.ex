defmodule ArchLens.Facade.Boundary do
  @moduledoc """
  Declare an outbound HTTP / external-party boundary on the current module.

  Unlike the PubSub and Oban facades, `boundary/1,2` wraps nothing: it is a pure
  declaration used on an adapter for a third party (Stripe, Cloudflare, ...). It
  records one `:http_boundary` `ArchLens.Edge`, keyed by
  `{{module, name}, {module, file, line}}`, and emits no runtime code, so it
  cannot change any call behaviour.

  The enclosing module must `use ArchLens.Facade` so the edge can be collected.

      defmodule MyApp.StripeClient do
        use ArchLens.Facade

        boundary :stripe, target: "https://api.stripe.com", via: :req

        def charge(params), do: Req.post("https://api.stripe.com/v1/charges", json: params)
      end

  `name` and every option must be compile-time literals; the options are stored on
  the edge's `metadata`, with `:target` also lifted onto the edge's `target`.
  """

  alias ArchLens.Edge
  alias ArchLens.Facade

  @doc """
  Declare a boundary named `name` with literal `opts` (e.g. `target:`, `via:`).

  Registers an `:http_boundary` edge and expands to no runtime code.
  """
  defmacro boundary(name, opts \\ []) do
    caller = __CALLER__
    opts = normalize_opts(opts)

    Facade.put_edge(caller.module, %Edge{
      kind: :http_boundary,
      builder: {caller.module, name},
      call_sites: [{caller.file, caller.line}],
      target: Keyword.get(opts, :target),
      metadata: Map.new(opts)
    })

    :ok
  end

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(_opts), do: []
end
