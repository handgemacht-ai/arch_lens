defmodule ArchLens.Collect.Decisions do
  @moduledoc """
  Indexes the architecture-decision records (ADRs) under the configured decisions
  directory into deterministic, verbatim-front-matter elements.

  An ADR is a `docs/decisions/NNNN-slug.md` file (four-digit number + `[a-z0-9-]`
  slug) whose top of file is a minimal front-matter block; the prose body below is
  hand-written and is **never** read into the artifact. `scan/1` reads the
  directory once and returns

      %{decisions: [element], errors: [{path, reason}]}

  sorted deterministically by ADR number (`File.ls/1` order is unstable, so the
  list is always sorted). Each clean element is

      %{
        id: "adr:0001",
        number: "0001",
        slug: "rest-api-ashjsonapi",
        title: <verbatim>,
        status: <verbatim>,
        date: <verbatim>,
        source: "declared",
        path: "docs/decisions/0001-rest-api-ashjsonapi.md"
      }

  ## Front-matter grammar (no YAML dependency)

  A `---` fence, then `key: value` lines, then a closing `---`. The three required
  keys are `title` (non-blank), `status` (`proposed|accepted|rejected|superseded|deprecated`),
  and `date` (`YYYY-MM-DD`, `Date.from_iso8601/1`-valid). Unknown keys (e.g. MADR
  `deciders`, `tags`) are tolerated and ignored, so a typo in a required key still
  trips the gate while extra fields do not. A leading UTF-8 BOM, CRLF/CR line
  endings, and single/double-quoted values are tolerated.

  ## Validity, not completeness

  A file that is present must be a well-formed, honestly-indexable record; every
  malformed file lands in `errors` (fed to the decisions gate). We do **not**
  enforce that a decision exists for anything — an app with no decisions directory
  is a legitimate empty state.

  ## Escape hatches

    * Reserved filenames `README.md`, `template.md`, and `0000-template.md` are
      skipped and never indexed (the adr-tools index/template convention).
    * To retire a decision, set its `status` to `superseded`, `deprecated`, or
      `rejected` — it stays indexed with that status rather than being dropped.
    * A missing decisions directory (or `config :arch_lens, decisions_dir: false`)
      yields `%{decisions: [], errors: []}` — the gate passes vacuously.
  """

  @default_dir "docs/decisions"
  @reserved ~w(README.md template.md 0000-template.md)
  @statuses ~w(proposed accepted rejected superseded deprecated)
  @filename_re ~r/^(\d{4})-([a-z0-9-]+)\.md$/

  @type element :: %{
          id: String.t(),
          number: String.t(),
          slug: String.t(),
          title: String.t(),
          status: String.t(),
          date: String.t(),
          source: String.t(),
          path: String.t()
        }

  @type result :: %{decisions: [element()], errors: [{String.t(), String.t()}]}

  @doc """
  Scan the decisions directory into `%{decisions: [...], errors: [...]}`.

  `nil` resolves to the default `#{@default_dir}` directory; `false` disables ADR
  indexing entirely; a string is used verbatim (repo-relative, resolved against the
  process cwd, exactly like the artifact path). A missing directory is not an error.
  """
  @spec scan(String.t() | false | nil) :: result()
  def scan(dir \\ nil)

  def scan(false), do: empty()
  def scan(nil), do: scan(@default_dir)

  def scan(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&candidate?/1)
        |> Enum.map(&index_file(dir, &1))
        |> partition()

      {:error, _reason} ->
        empty()
    end
  end

  defp empty, do: %{decisions: [], errors: []}

  # Only `.md` files are ADR candidates; the reserved index/template files are
  # skipped before any parsing so they never surface as errors.
  defp candidate?(name), do: String.ends_with?(name, ".md") and name not in @reserved

  defp index_file(dir, filename) do
    path = Path.join(dir, filename)

    case Regex.run(@filename_re, filename) do
      [_full, number, slug] ->
        read_and_parse(dir, filename, number, slug)

      nil ->
        {:error, {path, "filename must match NNNN-slug.md (four-digit number + lowercase slug)"}}
    end
  end

  defp read_and_parse(dir, filename, number, slug) do
    path = Path.join(dir, filename)

    with {:ok, content} <- read(path),
         {:ok, pairs} <- front_matter(content),
         {:ok, title, status, date} <- required_keys(pairs) do
      {:ok,
       %{
         id: "adr:" <> number,
         number: number,
         slug: slug,
         title: title,
         status: status,
         date: date,
         source: "declared",
         path: path
       }}
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "could not read file (#{:file.format_error(reason)})"}
    end
  end

  # Split the front-matter fence out of the file body. The very top of the file
  # must be a `---` line; everything up to the next `---` is the key/value block.
  defp front_matter(content) do
    case content |> strip_bom() |> lines() do
      ["---" | rest] -> collect_pairs(rest, [])
      _other -> {:error, "missing front-matter block (expected a leading `---` fence)"}
    end
  end

  defp collect_pairs([], _acc),
    do: {:error, "unterminated front-matter block (missing closing `---`)"}

  defp collect_pairs(["---" | _body], acc), do: {:ok, pairs(Enum.reverse(acc))}
  defp collect_pairs([line | rest], acc), do: collect_pairs(rest, [line | acc])

  defp pairs(front_matter_lines) do
    Enum.reduce(front_matter_lines, %{}, fn line, acc ->
      case pair(line) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  # A `key: value` line. Blank lines and lines without a colon are tolerated and
  # ignored (they cannot be one of the three required keys, so honesty holds).
  defp pair(line) do
    if String.trim(line) == "" do
      :skip
    else
      case String.split(line, ":", parts: 2) do
        [key, value] -> {:ok, String.trim(key), value |> String.trim() |> unquote_value()}
        [_no_colon] -> :skip
      end
    end
  end

  defp required_keys(pairs) do
    with {:ok, title} <- fetch(pairs, "title", &validate_title/1),
         {:ok, status} <- fetch(pairs, "status", &validate_status/1),
         {:ok, date} <- fetch(pairs, "date", &validate_date/1) do
      {:ok, title, status, date}
    end
  end

  defp fetch(pairs, key, validate) do
    case Map.fetch(pairs, key) do
      {:ok, value} -> validate.(value)
      :error -> {:error, "missing required key `#{key}`"}
    end
  end

  defp validate_title(value) do
    if String.trim(value) == "", do: {:error, "blank `title`"}, else: {:ok, value}
  end

  defp validate_status(value) do
    if value in @statuses do
      {:ok, value}
    else
      {:error,
       "invalid `status` #{inspect(value)} (expected one of #{Enum.join(@statuses, ", ")})"}
    end
  end

  defp validate_date(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> {:ok, value}
      {:error, _reason} -> {:error, "invalid `date` #{inspect(value)} (expected YYYY-MM-DD)"}
    end
  end

  # Split ok/error results, promote duplicate ADR numbers to errors, and sort both
  # lists by their stable key so a directory scanned twice is byte-identical.
  defp partition(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    decisions = Enum.map(oks, fn {:ok, element} -> element end)
    parse_errors = Enum.map(errors, fn {:error, error} -> error end)
    {unique, dup_errors} = split_duplicates(decisions)

    %{
      decisions: Enum.sort_by(unique, & &1.number),
      errors: Enum.sort_by(parse_errors ++ dup_errors, fn {path, _reason} -> path end)
    }
  end

  defp split_duplicates(decisions) do
    by_number = Enum.group_by(decisions, & &1.number)

    {unique, dups} =
      Enum.split_with(decisions, fn decision ->
        length(Map.fetch!(by_number, decision.number)) == 1
      end)

    dup_errors =
      Enum.map(dups, fn decision ->
        {decision.path, "duplicate decision number #{decision.number}"}
      end)

    {unique, dup_errors}
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp lines(content), do: String.split(content, ~r/\r\n|\r|\n/)

  defp unquote_value(value) do
    cond do
      wrapped?(value, "\"") -> unwrap(value)
      wrapped?(value, "'") -> unwrap(value)
      true -> value
    end
  end

  defp wrapped?(value, quote_char) do
    String.length(value) >= 2 and String.starts_with?(value, quote_char) and
      String.ends_with?(value, quote_char)
  end

  defp unwrap(value), do: String.slice(value, 1..-2//1)
end
