defmodule ArchLens.Generator.Scan do
  @moduledoc """
  DB-free discovery of the modules the generator reports on.

  Enumerates an OTP application's compiled module list (read from its `.app`
  metadata via `:application.get_key/2`, never a database) and filters it down to
  Ash resources and Oban workers.

  The plain module scan is deliberately independent of any domain's `resources`
  block. A resource that is *embedded* in another resource — and therefore absent
  from every domain's resource list — is still discovered here, which is why the
  generator unions this scan against the domain resources rather than trusting the
  domains alone.
  """

  alias ArchLens.Edge.Registry
  alias Ash.Resource.Info, as: ResourceInfo

  @doc """
  Every Ash resource compiled into `app`, sorted by module name.

  `nil` yields an empty list so callers can pass an unresolved app without a
  guard.
  """
  @spec ash_resources(atom() | nil) :: [module()]
  def ash_resources(nil), do: []

  def ash_resources(app) when is_atom(app) do
    app |> app_modules() |> ash_resources_from_modules()
  end

  @doc """
  Filters an explicit module list down to the Ash resources it contains, sorted
  by module name and de-duplicated. Pure: `ash_resources/1` is this applied to an
  app's module list.
  """
  @spec ash_resources_from_modules([module()]) :: [module()]
  def ash_resources_from_modules(modules) do
    modules
    |> Enum.filter(&ash_resource?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  @doc """
  Every Oban worker compiled into `app`, sorted by module name.

  Always empty when Oban is not loadable, so a scanned app with Oban absent — or
  present but with zero jobs registered — renders cleanly.
  """
  @spec oban_workers(atom() | nil) :: [module()]
  def oban_workers(nil), do: []

  def oban_workers(app) when is_atom(app) do
    app |> app_modules() |> oban_workers_from_modules()
  end

  @doc "Filters an explicit module list down to the Oban workers it contains."
  @spec oban_workers_from_modules([module()]) :: [module()]
  def oban_workers_from_modules(modules) do
    if Registry.oban_available?() do
      modules
      |> Enum.filter(&oban_worker?/1)
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)
    else
      []
    end
  end

  @doc """
  Every module compiled into `app`, read from its `.app` metadata (never a
  database). `nil` yields an empty list.
  """
  @spec app_modules(atom() | nil) :: [module()]
  def app_modules(nil), do: []

  def app_modules(app) when is_atom(app) do
    _ = Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end

  defp ash_resource?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and ResourceInfo.resource?(module)
  end

  defp ash_resource?(_), do: false

  defp oban_worker?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :perform, 1) and
      behaviour?(module, Oban.Worker)
  end

  defp oban_worker?(_), do: false

  defp behaviour?(module, behaviour) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  rescue
    _ -> false
  end
end
