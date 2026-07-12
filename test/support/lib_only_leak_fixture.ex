# A test-support module shaped exactly like a real bounded context — a directory
# root carrying a @moduledoc, with a child module — i.e. the eval-lab
# `EvalLab.ParityCorpus` shape. Compiled under test/support (an extra elixirc_path),
# it belongs to the :arch_lens application's module list ONLY under MIX_ENV=test.
#
# It exists to prove the lib-only production scan (ArchLens.Generator.Scan) keeps
# such a module out of discovery, the gates, and the artifact: unfiltered it would
# surface as a `lib_only_leak_fixture` context under :test but not :dev, drifting the
# generated artifact by environment.
defmodule ArchLens.LibOnlyLeakFixture do
  @moduledoc "A test-support context-shaped module the lib-only scan must exclude."
end

defmodule ArchLens.LibOnlyLeakFixture.Entry do
  @moduledoc false
  def entry, do: :ok
end
