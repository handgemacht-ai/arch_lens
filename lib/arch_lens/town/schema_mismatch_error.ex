defmodule ArchLens.Town.SchemaMismatchError do
  @moduledoc """
  Raised by `ArchLens.Town.combine/1` when a manifest input artifact carries a
  `schema_version` other than the per-app artifact schema the town combiner expects
  (`ArchLens.Generator.Model.schema_version/0`).

  Joining or comparing artifacts across incompatible schemas is meaningless, so a
  stale input must be regenerated at the current `arch_lens` version — or dropped
  from the manifest until it is upgraded. Mirrors
  `ArchLens.Diff.SchemaMismatchError`.
  """

  defexception [:path, :version, :expected]

  @impl true
  def message(%__MODULE__{path: path, version: version, expected: expected}) do
    "arch_lens.town.map: #{path} is schema_version #{inspect(version)}, but the town " <>
      "combiner requires schema_version #{inspect(expected)} (the per-app arch_lens artifact " <>
      "schema). Regenerate that app with `mix arch_lens.gen.architecture` at the current " <>
      "arch_lens version and commit it, or drop its entry from the manifest until it is upgraded."
  end
end
