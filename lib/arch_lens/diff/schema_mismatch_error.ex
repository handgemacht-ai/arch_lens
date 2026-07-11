defmodule ArchLens.Diff.SchemaMismatchError do
  @moduledoc """
  Raised by `ArchLens.Diff.compute/2` when the baseline and candidate models carry
  different `schema_version`s. Deltas across incompatible schemas are meaningless,
  so callers must regenerate both artifacts at the same `arch_lens` version.
  """

  defexception [:baseline_version, :candidate_version]

  @impl true
  def message(%__MODULE__{baseline_version: base, candidate_version: cand}) do
    "arch_lens.diff: schema_version mismatch — the baseline is schema_version " <>
      "#{inspect(base)} but the candidate is #{inspect(cand)}. A cross-version diff is not " <>
      "supported: regenerate the committed baseline with `mix arch_lens.gen.architecture` at " <>
      "the candidate's arch_lens version, commit it, then re-run the diff."
  end
end
