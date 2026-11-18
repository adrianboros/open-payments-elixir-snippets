defmodule OpenPaymentsSnippets.Input do
  @moduledoc false

  @spec json(String.t() | nil, String.t()) :: {:ok, term()} | {:error, String.t()}
  def json(source, label) do
    with {:ok, data} <- read(source, label) do
      case Jason.decode(data) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _error} -> {:error, "#{String.capitalize(label)} must contain valid JSON."}
      end
    end
  end

  defp read(source, _label) when source in [nil, ""],
    do: {:error, "Supply a JSON file or - for stdin."}

  defp read("-", label) do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> {:error, "Unable to read #{label} from stdin."}
      :eof -> {:ok, ""}
      data -> {:ok, data}
    end
  end

  defp read(path, label) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, "Unable to read #{label} file."}
    end
  end
end
