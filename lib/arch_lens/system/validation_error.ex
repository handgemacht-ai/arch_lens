defmodule ArchLens.System.ValidationError do
  @moduledoc """
  Raised at generation time when a declared architecture cannot be reconciled with
  what the generator collected.

  Carries every failing check (`errors`) so one message names all of them, rather
  than failing on the first.
  """

  defexception [:errors]

  @type t :: %__MODULE__{errors: [String.t()]}

  @impl true
  def message(%__MODULE__{errors: errors}) do
    bullets = errors |> Enum.map(&("  - " <> &1)) |> Enum.join("\n")

    "declared architecture does not match what was collected:\n" <>
      bullets <>
      "\nFix the declarations in your `ArchLens.System` module or re-collect."
  end
end
