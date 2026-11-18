defmodule OpenPaymentsSnippets.Commands.Quotes do
  @moduledoc false

  alias OpenPayments.{Error, Quote}
  alias OpenPayments.Types.Quote, as: QuoteData
  alias OpenPaymentsSnippets.Config

  @spec get(String.t(), keyword()) ::
          {:ok, QuoteData.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      Quote.get(client, url, access_token: token)
    end
  end
end
