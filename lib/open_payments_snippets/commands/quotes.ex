defmodule OpenPaymentsSnippets.Commands.Quotes do
  @moduledoc false

  alias OpenPayments.{Error, Quote, WalletAddress}
  alias OpenPayments.Types.CreateQuote
  alias OpenPayments.Types.Quote, as: QuoteData
  alias OpenPaymentsSnippets.{Config, Input}

  @spec get(String.t(), keyword()) ::
          {:ok, QuoteData.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      Quote.get(client, url, access_token: token)
    end
  end

  @spec create(String.t() | nil, keyword()) ::
          {:ok, QuoteData.t()} | {:error, Error.t() | String.t()}
  def create(source, options) do
    with {:ok, data} <- Input.json(source, "quote request"),
         {:ok, request} <- CreateQuote.from_map(data),
         {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options),
         {:ok, wallet} <- WalletAddress.get(client, request.wallet_address) do
      Quote.create(client, wallet.resource_server, request, access_token: token)
    else
      {:error, %Error{operation: nil} = error} ->
        {:error, %{error | operation: :create_quote}}

      {:error, error} ->
        {:error, error}
    end
  end
end
