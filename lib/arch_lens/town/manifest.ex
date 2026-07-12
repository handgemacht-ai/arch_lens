defmodule ArchLens.Town.Manifest do
  @moduledoc """
  Loads the town combiner's dumb pointer manifest and the per-app artifacts it
  names.

  The manifest (`town-arch.manifest.json`) is a plain JSON file:

      {
        "apps": [
          {"artifact": "../havi/docs/architecture.gen.json"},
          {"artifact": "../claude-code-course/docs/architecture.gen.json"}
        ],
        "output": "docs/town-architecture.gen.md"
      }

  Identity and aliases live INSIDE each artifact's `app` block, not here — so a
  town member is declared once, in place. Every path in the manifest is resolved
  relative to the manifest's own directory, so the manifest is portable across
  checkouts.

  `load/1` reads and decodes the manifest and every input artifact, enforcing the
  missing-input gate (a named artifact that does not exist fails, naming the path —
  never silently skipped) and surfacing malformed JSON. The
  schema-version/duplicate-identity gates are the pure combiner's
  (`ArchLens.Town.combine/1`).
  """

  @type loaded :: %{
          inputs: [%{path: String.t(), model: map()}],
          output_md: String.t(),
          output_json: String.t()
        }

  @type error ::
          {:manifest_not_found, String.t()}
          | {:invalid_manifest_json, String.t(), String.t()}
          | {:manifest_missing_key, String.t()}
          | {:missing_input, String.t()}
          | {:invalid_input_json, String.t(), String.t()}

  @doc """
  Read `manifest_path`, resolve its paths, and load every input artifact.

  Returns `{:ok, %{inputs: [%{path, model}], output_md, output_json}}` where each
  `model` is the decoded per-app artifact, or `{:error, reason}` for a missing or
  malformed manifest, a missing key, a missing input artifact, or malformed input
  JSON.
  """
  @spec load(String.t()) :: {:ok, loaded()} | {:error, error()}
  def load(manifest_path) do
    base = Path.dirname(manifest_path)

    with {:ok, raw} <- read(manifest_path, {:manifest_not_found, manifest_path}),
         {:ok, manifest} <- decode(raw, &{:invalid_manifest_json, manifest_path, &1}),
         {:ok, artifacts} <- artifact_paths(manifest, base),
         {:ok, output_md} <- output_path(manifest, base),
         {:ok, inputs} <- load_inputs(artifacts) do
      {:ok,
       %{inputs: inputs, output_md: output_md, output_json: Path.rootname(output_md) <> ".json"}}
    end
  end

  defp artifact_paths(%{"apps" => apps}, base) when is_list(apps) do
    paths =
      apps
      |> Enum.map(&entry_artifact/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.expand(&1, base))

    {:ok, paths}
  end

  defp artifact_paths(_manifest, _base), do: {:error, {:manifest_missing_key, "apps"}}

  defp entry_artifact(%{"artifact" => artifact}) when is_binary(artifact), do: artifact
  defp entry_artifact(_entry), do: nil

  defp output_path(%{"output" => output}, base) when is_binary(output),
    do: {:ok, Path.expand(output, base)}

  defp output_path(_manifest, _base), do: {:error, {:manifest_missing_key, "output"}}

  defp load_inputs(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case load_input(path) do
        {:ok, input} -> {:cont, {:ok, [input | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp load_input(path) do
    with {:ok, raw} <- read(path, {:missing_input, path}),
         {:ok, model} <- decode(raw, &{:invalid_input_json, path, &1}) do
      {:ok, %{path: path, model: model}}
    end
  end

  defp read(path, not_found) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, not_found}
      {:error, reason} -> {:error, {:missing_input, "#{path} (#{:file.format_error(reason)})"}}
    end
  end

  defp decode(raw, error_fun) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, error_fun.("not a JSON object")}
      {:error, error} -> {:error, error_fun.(Exception.message(error))}
    end
  end
end
