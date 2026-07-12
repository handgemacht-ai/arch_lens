defmodule Mix.Tasks.ArchLens.Town.Map do
  @shortdoc "Generate (or --check) the combined town-level architecture map"

  @moduledoc """
  Combines the committed per-app `architecture.gen.json` artifacts named by a town
  manifest into one cross-app map and writes both `town-architecture.gen.md` and its
  JSON sidecar (the manifest's `output` and its `.json` sibling).

  ## Usage

      mix arch_lens.town.map                          # write both artifacts
      mix arch_lens.town.map --check                  # fail on drift, write nothing
      mix arch_lens.town.map --manifest path/to.json  # non-default manifest

  The manifest (default `town-arch.manifest.json`) is a dumb pointer file; identity
  and aliases live inside each per-app artifact's `app` block. See
  `ArchLens.Town.Manifest`.

  ## `--check` mode

  Re-renders both town artifacts and compares each byte-for-byte against its
  committed file, exiting non-zero and *naming the file* on any drift — the same
  idiom as `mix arch_lens.gen.architecture --check`. Because the combined map drifts
  whenever any input app regenerates, run this in the town-level job (where all input
  artifacts are on disk), not in a single app's CI.

  ## Gates

    * missing input artifact — fails, naming the path (`ArchLens.Town.Manifest`).
    * input schema mismatch — fails via `ArchLens.Town.SchemaMismatchError`.
    * duplicate app identity — fails, naming both files.

  The task is DB-free and compiles nothing: it reads only committed JSON.
  """

  use Mix.Task

  alias ArchLens.Generator.Model
  alias ArchLens.Town
  alias ArchLens.Town.{Document, Manifest}

  @default_manifest "town-arch.manifest.json"

  @switches [manifest: :string, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    manifest = Keyword.get(opts, :manifest, @default_manifest)
    emit(manifest, Keyword.get(opts, :check, false))
  end

  @doc false
  # Load the manifest + inputs, combine into the town map, render both artifacts, and
  # either write both or (in `--check` mode) compare both. Any gate failure aborts via
  # `Mix.raise/1` (non-zero exit). Split out so the load/combine/render/write glue is
  # exercised with an explicit manifest path in tests.
  @spec emit(String.t(), boolean()) :: :ok
  def emit(manifest_path, check?) do
    with {:ok, loaded} <- Manifest.load(manifest_path),
         {:ok, town_map} <- Town.combine(loaded.inputs) do
      output(town_map, loaded, check?)
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  rescue
    error in Town.SchemaMismatchError -> Mix.raise(Exception.message(error))
  end

  defp output(town_map, %{output_md: md_path, output_json: json_path}, check?) do
    markdown = Document.render(town_map)
    json = Model.encode(town_map)

    if check? do
      check(md_path, markdown)
      check(json_path, json)
    else
      write(md_path, markdown)
      write(json_path, json)
    end
  end

  defp check(path, content) do
    cond do
      not File.exists?(path) ->
        Mix.raise(
          "town map is stale: #{path} (missing committed artifact). " <>
            "Run `mix arch_lens.town.map` and commit #{path}."
        )

      File.read!(path) == content ->
        Mix.shell().info("town map up to date: #{path}")

      true ->
        Mix.raise(
          "town map is stale: #{path} (generated output differs from committed artifact). " <>
            "Run `mix arch_lens.town.map` and commit #{path}."
        )
    end
  end

  defp write(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    Mix.shell().info("wrote town map: #{path}")
  end

  defp format_error({:manifest_not_found, path}),
    do: "arch_lens.town.map: manifest not found: #{path}."

  defp format_error({:invalid_manifest_json, path, message}),
    do: "arch_lens.town.map: manifest #{path} is not valid JSON: #{message}."

  defp format_error({:manifest_missing_key, key}),
    do: "arch_lens.town.map: manifest is missing the #{inspect(key)} key."

  defp format_error({:missing_input, path}),
    do:
      "arch_lens.town.map: manifest input artifact not found: #{path}. " <>
        "Generate it with `mix arch_lens.gen.architecture` in that app, or remove its manifest entry."

  defp format_error({:invalid_input_json, path, message}),
    do: "arch_lens.town.map: input artifact #{path} is not valid JSON: #{message}."

  defp format_error({:duplicate_identity, id, paths}),
    do:
      "arch_lens.town.map: duplicate app identity #{inspect(id)} declared by #{Enum.join(paths, " and ")}. " <>
        "Town app ids must be unique — give one app a distinct `identity` id."
end
