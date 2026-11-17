defmodule OpenPaymentsSnippets.Commands.Grants do
  @moduledoc false

  alias OpenPayments.Error
  alias OpenPayments.Types.GrantRequest

  @spec validate(String.t() | nil) :: {:ok, %{valid: true}} | {:error, String.t()}
  def validate(source) do
    with {:ok, json} <- read(source),
         {:ok, data} <- decode(json),
         {:ok, _request} <- GrantRequest.from_map(data) do
      {:ok, %{valid: true}}
    else
      {:error, %Error{validation_errors: issues}} ->
        details =
          Enum.map(issues, fn %{field: field, message: message} -> "#{field}  #{message}" end)

        {:error, Enum.join(["Invalid grant request." | details], "\n")}

      {:error, message} ->
        {:error, message}
    end
  end

  defp read(source) when source in [nil, ""],
    do: {:error, "Supply a JSON file or - for stdin."}

  defp read("-") do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> {:error, "Unable to read grant request from stdin."}
      :eof -> {:ok, ""}
      data -> {:ok, data}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, "Unable to read grant request file."}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, data}
      {:error, _error} -> {:error, "Grant request must contain valid JSON."}
    end
  end
end
