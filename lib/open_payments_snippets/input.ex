defmodule OpenPaymentsSnippets.Input do
  @moduledoc false
  alias OpenPaymentsSnippets.Environment

  @spec json(String.t() | nil, String.t(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def json(source, label, options \\ []) do
    with {:ok, data} <- read(source, label) do
      case Jason.decode(data) do
        {:ok, decoded} -> expand(decoded, options)
        {:error, _error} -> {:error, "#{String.capitalize(label)} must contain valid JSON."}
      end
    end
  end

  defp expand(%{"$var" => name} = reference, options) do
    with true <- map_size(Map.drop(reference, ["$var", "type"])) == 0,
         {:ok, value} <- Environment.variable(options, name) do
      case Map.get(reference, "type", "string") do
        "string" -> {:ok, value}
        "integer" -> integer(value)
        _ -> {:error, "Template variable type must be string or integer."}
      end
    else
      false -> {:error, "Template variable references accept only $var and type."}
      error -> error
    end
  end

  defp expand(data, options) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case expand(value, options) do
        {:ok, value} -> {:cont, {:ok, Map.put(result, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp expand(data, options) when is_list(data) do
    Enum.reduce_while(data, {:ok, []}, fn item, {:ok, result} ->
      case expand(item, options) do
        {:ok, item} -> {:cont, {:ok, [item | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp expand(literal, _options), do: {:ok, literal}

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "Integer template variables must contain a whole number."}
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
