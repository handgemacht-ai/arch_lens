defmodule ArchLens.Collect.Runtime do
  @moduledoc """
  Collects the host app's runtime shape into `ArchLens.Generator.Scope`'s
  `runtime_components` seam.

  Three sources fold into one deterministic, id-sorted list, every element tagged
  `source: "collected"`:

    * **datastores** — one element per `config :app, :ecto_repos` entry, with the
      backing technology derived from the repo adapter when introspectable.
    * **job runners** — an Oban runner when Oban is configured/loaded, plus one
      element per named `Task.Supervisor` child seen in the live tree.
    * **runtime components** — the app's top-level supervision tree walked with
      `Supervisor.which_children/1` on the root supervisor the wrapper passes in,
      each child classified (Repo, Phoenix.PubSub, Endpoint, Oban,
      Task.Supervisor, Telemetry, DNSCluster, or custom).

  When the tree is not running (`:root_supervisor` absent, unregistered, or dead),
  collection **degrades gracefully** to the config-only sources (datastores + the
  Oban runner). Live-tree elements merge with config-derived ones by id, so a Repo
  seen both in `:ecto_repos` and in the tree is one element carrying both
  evidences.

  This module runs in the host app's context (invoked by a wrapper mix task with
  the app loaded/started). `arch_lens` takes no hard dependency on Ecto, Oban,
  Phoenix or DNSCluster: every framework touch is behind a `Code.ensure_loaded?/1`
  / `function_exported?/3` guard or a name check, and no process pid ever reaches
  an element, so the output stays deterministic.

  ## Options

    * `:otp_app` — the host OTP application (drives `:ecto_repos` and `Oban` env
      lookups).
    * `:root_supervisor` — the root supervisor name or pid to walk; omit for
      config-only collection.
    * `:ecto_repos` — override the repo list (defaults to
      `Application.get_env(otp_app, :ecto_repos)`).
    * `:oban_config` — override the Oban config (defaults to
      `Application.get_env(otp_app, Oban)`).
    * `:supervisor_children` — inject an explicit `which_children/1` result (a
      `[{id, child, type, modules}]` list) instead of walking a live tree; the
      testing/degradation seam.
  """

  alias ArchLens.Edge

  @type element :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:class) => String.t(),
          required(:source) => String.t(),
          required(:evidence) => [String.t()],
          optional(:technology) => String.t()
        }

  @doc """
  The merged, id-sorted runtime-component list for `Scope.runtime_components`.

  Unions datastores, job runners, and the (optional) live supervision tree,
  merging same-id elements. Degrades to config-only when no live tree is reachable.
  """
  @spec collect(keyword()) :: [element()]
  def collect(opts \\ []) do
    (datastores(opts) ++ job_runners(opts) ++ components(opts))
    |> merge_by_id()
    |> Enum.sort_by(& &1.id)
  end

  @doc "Datastore elements, one per configured Ecto repo."
  @spec datastores(keyword()) :: [element()]
  def datastores(opts) do
    opts
    |> ecto_repos()
    |> Enum.map(&datastore_element/1)
  end

  @doc """
  Config-derived job-runner elements: the Oban runner when Oban is
  configured/loaded. Named `Task.Supervisor` runners are surfaced by the live-tree
  walk (`components/1`), not from config.
  """
  @spec job_runners(keyword()) :: [element()]
  def job_runners(opts) do
    oban_runner(opts)
  end

  @doc """
  Elements classified from the live supervision tree, or `[]` when no live tree is
  reachable (the config-only degradation).
  """
  @spec components(keyword()) :: [element()]
  def components(opts) do
    case supervisor_children(opts) do
      :not_running -> []
      children -> Enum.map(children, &classify_child/1)
    end
  end

  # --- datastores ---------------------------------------------------------

  defp ecto_repos(opts) do
    Keyword.get_lazy(opts, :ecto_repos, fn ->
      case Keyword.get(opts, :otp_app) do
        nil -> []
        app -> Application.get_env(app, :ecto_repos, [])
      end
    end)
  end

  defp datastore_element(repo) do
    %{
      id: "datastore:" <> name(repo),
      label: name(repo),
      class: "repo",
      source: "collected",
      evidence: ["config:ecto_repos"]
    }
    |> maybe_put(:technology, repo_technology(repo))
  end

  defp repo_technology(repo) do
    if is_atom(repo) and Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) do
      adapter_technology(repo.__adapter__())
    end
  rescue
    _ -> nil
  end

  defp adapter_technology(adapter) do
    case name(adapter) do
      "Ecto.Adapters.Postgres" -> "postgresql"
      "Ecto.Adapters.MyXQL" -> "mysql"
      "Ecto.Adapters.Tds" -> "sqlserver"
      "Ecto.Adapters.SQLite3" -> "sqlite"
      "Exqlite." <> _ -> "sqlite"
      other -> other
    end
  end

  # --- job runners (Oban) -------------------------------------------------

  defp oban_runner(opts) do
    case oban_config(opts) do
      nil ->
        []

      config ->
        oban_name = oban_name(config)

        [
          %{
            id: "runner:" <> oban_name,
            label: oban_name,
            class: "oban",
            source: "collected",
            evidence: ["config:oban"]
          }
        ]
    end
  end

  defp oban_config(opts) do
    Keyword.get_lazy(opts, :oban_config, fn ->
      case Keyword.get(opts, :otp_app) do
        nil -> nil
        app -> Application.get_env(app, Oban)
      end
    end)
  end

  defp oban_name(config) when is_list(config) do
    case Keyword.get(config, :name) do
      name when is_atom(name) and not is_nil(name) -> name(name)
      _ -> "Oban"
    end
  end

  defp oban_name(_config), do: "Oban"

  # --- supervision tree ---------------------------------------------------

  defp supervisor_children(opts) do
    case Keyword.fetch(opts, :supervisor_children) do
      {:ok, children} -> children
      :error -> live_children(Keyword.get(opts, :root_supervisor))
    end
  end

  defp live_children(nil), do: :not_running

  defp live_children(root) do
    case GenServer.whereis(root) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: which_children(pid), else: :not_running

      _ ->
        :not_running
    end
  rescue
    _ -> :not_running
  catch
    _, _ -> :not_running
  end

  defp which_children(pid) do
    Supervisor.which_children(pid)
  rescue
    _ -> :not_running
  catch
    _, _ -> :not_running
  end

  defp classify_child({id, _child, _type, modules}) do
    candidates = module_candidates(id, modules)
    class = classification(candidates)
    subject = subject(id, candidates)
    build_element(class, subject)
  end

  defp classify_child(_other), do: build_element("custom", :unknown)

  defp module_candidates(id, modules) do
    [id | List.wrap(modules)]
    |> Enum.filter(&module_atom?/1)
    |> Enum.uniq()
  end

  defp subject(id, candidates) do
    cond do
      module_atom?(id) -> id
      candidates != [] -> hd(candidates)
      true -> id
    end
  end

  defp classification(names) do
    cond do
      named?(names, "Oban") -> "oban"
      Enum.any?(names, &ecto_repo?/1) -> "repo"
      named?(names, "Task.Supervisor") -> "task_supervisor"
      named?(names, "Phoenix.PubSub") -> "pubsub"
      matches?(names, ~r/Endpoint$/) -> "endpoint"
      named?(names, "DNSCluster") -> "dns_cluster"
      matches?(names, ~r/(^|\.)Telemetry$/) -> "telemetry"
      true -> "custom"
    end
  end

  defp build_element(class, subject) do
    %{
      id: id_prefix(class) <> label(subject),
      label: label(subject),
      class: class,
      source: "collected",
      evidence: ["supervision_tree"]
    }
    |> maybe_put(:technology, class == "repo" && repo_technology(subject))
  end

  defp id_prefix("repo"), do: "datastore:"
  defp id_prefix(class) when class in ["oban", "task_supervisor"], do: "runner:"
  defp id_prefix(_class), do: "component:"

  defp label(subject) when is_atom(subject) and subject not in [nil, true, false],
    do: name(subject)

  defp label(subject), do: inspect(subject)

  # --- classification predicates -----------------------------------------

  defp named?(names, target), do: Enum.any?(names, &(name(&1) == target))

  defp matches?(names, regex), do: Enum.any?(names, &(name(&1) =~ regex))

  defp ecto_repo?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :__adapter__, 0)
  rescue
    _ -> false
  end

  defp module_atom?(value),
    do: is_atom(value) and value not in [nil, true, false, :undefined, :restarting]

  # --- merging ------------------------------------------------------------

  defp merge_by_id(elements) do
    elements
    |> Enum.reduce(%{}, fn element, acc ->
      Map.update(acc, element.id, element, &merge_elements(&1, element))
    end)
    |> Map.values()
  end

  defp merge_elements(existing, incoming) do
    existing
    |> Map.put(:evidence, merge_evidence(existing.evidence, incoming.evidence))
    |> maybe_put(:technology, existing[:technology] || incoming[:technology])
  end

  defp merge_evidence(a, b), do: (a ++ b) |> Enum.uniq() |> Enum.sort()

  # --- shared -------------------------------------------------------------

  defp name(module), do: Edge.module_name(module)

  defp maybe_put(map, _key, value) when value in [nil, false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
