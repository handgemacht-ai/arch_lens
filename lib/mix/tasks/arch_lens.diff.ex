defmodule Mix.Tasks.ArchLens.Diff do
  @shortdoc "Diff the architecture JSON sidecar against a baseline (git ref or file)"

  @moduledoc """
  Diffs the committed architecture JSON sidecar (`docs/architecture.gen.json`)
  against a baseline and reports the added / removed / changed architectural
  elements, keyed by their stable ids.

  ## Usage

      mix arch_lens.diff                         # vs origin/main, text report
      mix arch_lens.diff --format markdown       # PR-comment-ready block
      mix arch_lens.diff --base main             # vs a different git ref
      mix arch_lens.diff --fail-on-warn          # non-zero exit on any WARN

  ## Baseline (pick one)

    * `--base <git-ref>` (default `origin/main`): the baseline is read from git at
      the **merge base** of `<git-ref>` and `HEAD`
      (`git show <merge-base>:<path>`), so the diff reflects only what this branch
      changed, not what moved on the base branch. If the sidecar does not exist at
      that ref (first adoption), everything is reported as added.
    * `--base-file <path>`: read the baseline JSON from a file instead of git.

  ## Candidate

  The candidate defaults to the committed sidecar at `--path`
  (default `docs/architecture.gen.json`); `--candidate-file <path>` overrides it.

  ## Options

    * `--path <path>` — sidecar path, used for both the git baseline lookup and
      the default candidate (default `docs/architecture.gen.json`).
    * `--format json|text|markdown` — output format (default `text`). `markdown`
      is a compact PR-comment block: headline counts, **WARN** lines first, then
      INFO, `location_only` deltas suppressed, opened by a stable
      `<!-- arch-lens-diff -->` marker so CI can upsert the same comment.
    * `--fail-on-warn` — exit non-zero when the diff contains any WARN delta.
      Without it, the task always exits 0 (it still prints the report).

  A `schema_version` mismatch between baseline and candidate aborts with a clear
  error; regenerate both artifacts at the same `arch_lens` version first.
  """

  use Mix.Task

  alias ArchLens.Diff
  alias ArchLens.Generator.Architecture

  @requirements ["compile"]

  @switches [
    base: :string,
    base_file: :string,
    path: :string,
    candidate_file: :string,
    format: :string,
    fail_on_warn: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    case report(opts) do
      {:ok, %{output: output, warn_count: warn_count}} ->
        Mix.shell().info(output)

        if Keyword.get(opts, :fail_on_warn, false) and warn_count > 0 do
          Mix.raise(
            "arch_lens.diff: #{warn_count} architecture warning(s); failing due to --fail-on-warn."
          )
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  # Resolve baseline + candidate, compute the diff, and render it. Returns
  # `{:ok, %{output, warn_count, result}}` or `{:error, message}`. Split out so
  # the resolve/decode/compute/render pipeline is exercised without the IO and
  # exit-code glue in `run/1`.
  @spec report(keyword()) :: {:ok, map()} | {:error, String.t()}
  def report(opts) do
    path = Keyword.get(opts, :path, Architecture.json_artifact())

    with {:ok, format} <- parse_format(Keyword.get(opts, :format, "text")),
         {:ok, candidate_raw} <- read_candidate(opts, path),
         {:ok, baseline_raw} <- read_baseline(opts, path),
         {:ok, candidate} <- decode(candidate_raw, "candidate sidecar"),
         {:ok, baseline} <- decode_baseline(baseline_raw) do
      compute_and_render(baseline, candidate, format)
    end
  end

  defp compute_and_render(baseline, candidate, format) do
    result = Diff.compute(baseline, candidate)

    {:ok,
     %{
       output: Diff.render(result, format),
       warn_count: Diff.warning_count(result),
       result: result
     }}
  rescue
    error in Diff.SchemaMismatchError -> {:error, Exception.message(error)}
  end

  # --- candidate ----------------------------------------------------------

  defp read_candidate(opts, path) do
    case Keyword.get(opts, :candidate_file) do
      nil ->
        read_file(
          path,
          "candidate sidecar not found: #{path}. Run mix arch_lens.gen.architecture."
        )

      file ->
        read_file(file, "candidate file not found: #{file}")
    end
  end

  # --- baseline -----------------------------------------------------------

  defp read_baseline(opts, path) do
    case Keyword.get(opts, :base_file) do
      nil -> read_baseline_from_git(Keyword.get(opts, :base, "origin/main"), path)
      file -> wrap_present(read_file(file, "base file not found: #{file}"))
    end
  end

  defp read_baseline_from_git(ref, path) do
    rev = merge_base(ref)

    case git(["show", "#{rev}:#{path}"]) do
      {:ok, content} ->
        {:ok, {:present, content}}

      {:error, output} ->
        classify_git_show_failure(output, ref)
    end
  end

  defp classify_git_show_failure(output, ref) do
    if unresolvable_ref?(output) do
      {:error, "arch_lens.diff: cannot resolve base ref #{inspect(ref)}: #{String.trim(output)}"}
    else
      # The ref resolves but the sidecar does not exist there: first adoption. The
      # rendered report itself notes the absent baseline, so nothing is printed here.
      {:ok, :absent}
    end
  end

  defp unresolvable_ref?(output) do
    Enum.any?(
      [
        "invalid object name",
        "unknown revision",
        "bad revision",
        "ambiguous argument",
        "Not a valid object name"
      ],
      &String.contains?(output, &1)
    )
  end

  defp merge_base(ref) do
    case git(["merge-base", ref, "HEAD"]) do
      {:ok, output} -> String.trim(output)
      {:error, _output} -> ref
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  # --- decode -------------------------------------------------------------

  defp decode_baseline(:absent), do: {:ok, nil}
  defp decode_baseline({:present, raw}), do: decode(raw, "baseline sidecar")

  defp decode(raw, label) do
    case Jason.decode(raw) do
      {:ok, %{} = model} ->
        {:ok, model}

      {:ok, _other} ->
        {:error, "arch_lens.diff: #{label} is not a JSON object."}

      {:error, error} ->
        {:error, "arch_lens.diff: #{label} is not valid JSON: #{Exception.message(error)}"}
    end
  end

  # --- helpers ------------------------------------------------------------

  defp parse_format("json"), do: {:ok, :json}
  defp parse_format("text"), do: {:ok, :text}
  defp parse_format("markdown"), do: {:ok, :markdown}

  defp parse_format(other),
    do:
      {:error,
       "arch_lens.diff: unknown --format #{inspect(other)} (expected json, text, or markdown)."}

  defp read_file(path, not_found_message) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, not_found_message}

      {:error, reason} ->
        {:error, "arch_lens.diff: cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp wrap_present({:ok, content}), do: {:ok, {:present, content}}
  defp wrap_present({:error, _message} = error), do: error
end
