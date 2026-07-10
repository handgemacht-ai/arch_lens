defmodule ArchLens.Privacy.Info do
  @moduledoc """
  Runtime introspection for the `ArchLens.Privacy` extension.

  Reads the declared `privacy` block (or `no_personal_data` marker) back off a
  compiled resource module.
  """

  alias ArchLens.Privacy.Declaration
  alias Spark.Dsl.Extension

  @type resource :: Spark.Dsl.t() | module()

  @doc """
  The normalized `ArchLens.Privacy.Declaration` for a resource, or `nil` when the
  resource declared `no_personal_data` or declared nothing.
  """
  @spec declaration(resource()) :: Declaration.t() | nil
  def declaration(resource) do
    Extension.get_persisted(resource, :arch_lens_privacy)
  end

  @doc "Whether the resource declared the `no_personal_data` marker."
  @spec no_personal_data?(resource()) :: boolean()
  def no_personal_data?(resource) do
    Extension.get_persisted(resource, :arch_lens_no_personal_data) == true
  end

  @doc "Whether the resource declared any privacy posture at all."
  @spec declared?(resource()) :: boolean()
  def declared?(resource) do
    declaration(resource) != nil or no_personal_data?(resource)
  end

  @doc "The declared data category, or `nil`."
  @spec data_category(resource()) :: atom() | nil
  def data_category(resource) do
    case declaration(resource) do
      %Declaration{data_category: value} -> value
      _ -> nil
    end
  end

  @doc "The declared retention policy, or `nil`."
  @spec retention(resource()) :: String.t() | nil
  def retention(resource) do
    case declaration(resource) do
      %Declaration{retention: value} -> value
      _ -> nil
    end
  end

  @doc "The declared legal basis, or `nil`."
  @spec legal_basis(resource()) :: atom() | nil
  def legal_basis(resource) do
    case declaration(resource) do
      %Declaration{legal_basis: value} -> value
      _ -> nil
    end
  end

  @doc """
  A single summary of the resource's privacy posture:

    * an `ArchLens.Privacy.Declaration` when a `privacy` block was declared,
    * `:no_personal_data` when the marker was declared,
    * `:undeclared` otherwise.
  """
  @spec posture(resource()) :: Declaration.t() | :no_personal_data | :undeclared
  def posture(resource) do
    cond do
      declaration = declaration(resource) -> declaration
      no_personal_data?(resource) -> :no_personal_data
      true -> :undeclared
    end
  end
end
