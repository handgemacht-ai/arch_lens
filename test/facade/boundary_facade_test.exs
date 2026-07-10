defmodule ArchLensBoundaryDemo.StripeClient do
  @moduledoc false
  use ArchLens.Facade

  boundary(:stripe, target: "https://api.stripe.com", via: :req)

  # A plain function the boundary declaration must leave completely untouched.
  def base_url, do: "https://api.stripe.com"
end

defmodule ArchLens.Facade.BoundaryFacadeTest do
  # async: false — the edge registry is a single named process shared across tests.
  use ExUnit.Case, async: false

  alias ArchLens.Edge
  alias ArchLens.Edge.Registry
  alias ArchLens.Facade
  alias ArchLensBoundaryDemo.StripeClient

  setup do
    Registry.reset()
    :ok
  end

  test "boundary registers an :http_boundary edge keyed by {builder, call_site}" do
    assert [%Edge{} = edge] = Facade.register_edges(StripeClient)

    assert edge.kind == :http_boundary
    assert edge.builder == {StripeClient, :stripe}
    assert {StripeClient, file, line} = edge.call_site
    assert is_binary(file) and is_integer(line)
    assert edge.target == "https://api.stripe.com"
    assert edge.metadata == %{target: "https://api.stripe.com", via: :req}
    assert Registry.fetch(edge.builder, edge.call_site) == {:ok, edge}
  end

  test "boundary is a pure declaration and changes no call behaviour" do
    assert StripeClient.base_url() == "https://api.stripe.com"
  end
end
