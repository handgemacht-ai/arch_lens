defmodule ArchLens.TaskFixtures do
  @moduledoc """
  Mix task fixtures for the `ArchLens.Collect.Tasks` and `ArchLens.Generator.Scan`
  mix-task discovery tests.

  Two real `Mix.Tasks.*` modules — one with a `@shortdoc`, one without — exercise
  the verbatim-shortdoc extraction and the honest no-shortdoc case. They live under
  `test/support` on purpose: because their compiled source is *not* under `lib/`,
  the lib-only scan (`ArchLens.Generator.Scan.mix_tasks/1`) must not surface them,
  which is exactly the "a task outside `lib/` stays out of scope" guarantee the
  scan test asserts. The collector unit tests reach them directly via the
  `:mix_task_modules` escape hatch / `from_modules/1`.
  """
end

defmodule Mix.Tasks.ArchLensFixture.WithShortdoc do
  @shortdoc "Fixture task that declares a shortdoc"
  @moduledoc false
  use Mix.Task

  @impl Mix.Task
  def run(_argv), do: :ok
end

defmodule Mix.Tasks.ArchLensFixture.NoShortdoc do
  @moduledoc false
  use Mix.Task

  @impl Mix.Task
  def run(_argv), do: :ok
end
