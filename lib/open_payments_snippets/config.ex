defmodule OpenPaymentsSnippets.Config do
  @moduledoc false

  alias OpenPayments.{Client, Error, Key}
  alias OpenPaymentsSnippets.Commands.Keys

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

  defp wallet_address(options) do
    case Keyword.get(options, :wallet_address, System.get_env("WALLET_ADDRESS")) do
      value when value in [nil, ""] -> {:error, "Supply --wallet-address or set WALLET_ADDRESS."}
      value -> {:ok, value}
    end
  end
end
