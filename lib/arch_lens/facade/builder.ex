defmodule ArchLens.Facade.Builder do
  @moduledoc """
  Infer the *builder* half of an edge key from the expression a facade wraps.

  The builder is the thing that constructs what crosses the boundary: the topic
  builder behind a `broadcast`, or the Oban worker behind an `oban_insert`. A
  remote call such as `Demo.Topics.org(org_id)` yields `{Demo.Topics, :org, 1}`;
  anything else falls back to the source text of the expression, which is still a
  stable, human-readable key.
  """

  @doc """
  The builder for `call_ast`, resolved in `env` so aliases expand to full module
  names.
  """
  @spec from_call(Macro.t(), Macro.Env.t()) :: mfa() | String.t()
  def from_call({{:., _, [module_ast, fun]}, _, args}, env)
      when is_atom(fun) and is_list(args) do
    case Macro.expand(module_ast, env) do
      module when is_atom(module) and not is_nil(module) -> {module, fun, length(args)}
      _ -> Macro.to_string({{:., [], [module_ast, fun]}, [], args})
    end
  end

  def from_call(other, _env), do: Macro.to_string(other)
end
