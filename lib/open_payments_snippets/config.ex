defmodule OpenPaymentsSnippets.Config do
  @moduledoc false

  alias OpenPayments.{Client, Error, Key}
  alias OpenPaymentsSnippets.Commands.Keys
  alias OpenPaymentsSnippets.Environment

  @spec authenticated_client(keyword()) :: {:ok, Client.t(), Key.t()} | {:error, String.t()}
  def authenticated_client(options) do
    with {:ok, key} <- Keys.load(options),
         {:ok, wallet} <- wallet_address(options),
         {:ok, client} <-
           Client.new_authenticated(
             wallet_address: wallet,
             key: key,
             allow_http: Keyword.get(options, :allow_http, false)
           ) do
      {:ok, client, key}
    else
      {:error, %Error{}} -> {:error, "Invalid wallet address or signing configuration."}
      {:error, message} -> {:error, message}
    end
  end

  @spec access_token(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def access_token(options) do
    case Keyword.fetch(options, :access_token_file) do
      {:ok, path} -> read_token(path)
      :error -> environment_token(options)
    end
  end

  defp wallet_address(options) do
    case Keyword.get(options, :wallet_address, Environment.get(options, "WALLET_ADDRESS")) do
      value when value in [nil, ""] -> {:error, "Supply --wallet-address or set WALLET_ADDRESS."}
      value -> {:ok, value}
    end
  end

  defp environment_token(options) do
    case Environment.get(options, "ACCESS_TOKEN", "") do
      "" ->
        {:error, "Supply --access-token-file or set ACCESS_TOKEN with a resource access token."}

      value ->
        {:ok, value}
    end
  end

  defp read_token(path) do
    case File.read(path) do
      {:ok, token} ->
        # Accept one conventional line ending from tools writing a token file.
        # All other whitespace/format validation remains with the SDK.
        ending = if String.ends_with?(token, "\r\n"), do: "\r\n", else: "\n"
        {:ok, String.replace_suffix(token, ending, "")}

      {:error, _reason} ->
        {:error, "Unable to read access-token file."}
    end
  end
end
