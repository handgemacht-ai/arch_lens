defmodule ArchLensObanDemo.Worker do
  @moduledoc false
  # Stand-in for an Oban worker: `new/1` returns a fake changeset term.
  def new(args), do: {:changeset, args}
end

defmodule ArchLensObanDemo.StubOban do
  @moduledoc false
  # Stand-in insert target injected via config, so the facade's pass-through can
  # be exercised whether or not real Oban is on the dependency tree.
  def insert(changeset), do: {:ok, {:inserted, changeset}}
  def insert(changeset, opts), do: {:ok, {:inserted, changeset, opts}}
end

defmodule ArchLensObanDemo.Enqueue do
  @moduledoc false
  use ArchLens.Facade

  alias ArchLensObanDemo.Worker

  def enqueue(user_id) do
    oban_insert(Worker.new(%{user_id: user_id}))
  end

  def enqueue_with_opts(user_id, opts) do
    oban_insert(Worker.new(%{user_id: user_id}), opts)
  end
end

defmodule ArchLens.Facade.ObanFacadeTest do
  # async: false — the edge registry and the :oban_module app env are global.
  use ExUnit.Case, async: false

  alias ArchLens.Edge.Registry
  alias ArchLens.Facade
  alias ArchLens.Facade.Oban, as: ObanFacade
  alias ArchLensObanDemo.Enqueue
  alias ArchLensObanDemo.StubOban
  alias ArchLensObanDemo.Worker

  setup do
    Registry.reset()
    previous = Application.get_env(:arch_lens, :oban_module)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:arch_lens, :oban_module)
        value -> Application.put_env(:arch_lens, :oban_module, value)
      end
    end)

    :ok
  end

  test "insert/1,2 returns {:error, :oban_not_loaded} when no insert target is available" do
    Application.put_env(:arch_lens, :oban_module, false)

    refute ObanFacade.available?()
    assert ObanFacade.insert({:changeset, %{}}) == {:error, :oban_not_loaded}
    assert ObanFacade.insert({:changeset, %{}}, priority: 1) == {:error, :oban_not_loaded}
  end

  test "oban_insert forwards the changeset (and opts) unchanged to the insert target" do
    Application.put_env(:arch_lens, :oban_module, StubOban)

    assert ObanFacade.available?()
    assert Enqueue.enqueue(7) == {:ok, {:inserted, {:changeset, %{user_id: 7}}}}

    assert Enqueue.enqueue_with_opts(7, priority: 1) ==
             {:ok, {:inserted, {:changeset, %{user_id: 7}}, [priority: 1]}}
  end

  test "an :oban_insert edge is registered keyed by {builder, call_site}" do
    edges = Facade.register_edges(Enqueue)

    oban_edges = Enum.filter(edges, &(&1.kind == :oban_insert))
    assert length(oban_edges) == 2
    assert Enum.all?(oban_edges, &(&1.builder == {Worker, :new, 1}))

    for edge <- oban_edges do
      assert {Enqueue, file, line} = edge.call_site
      assert is_binary(file) and is_integer(line)
      assert Registry.fetch(edge.builder, edge.call_site) == {:ok, edge}
    end
  end

  test "available?/0 answers without hard-requiring Oban" do
    Application.delete_env(:arch_lens, :oban_module)
    assert is_boolean(ObanFacade.available?())
  end
end
