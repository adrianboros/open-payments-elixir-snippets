defmodule OpenPaymentsSnippets.Commands.OutgoingPayments do
  @moduledoc false

  alias OpenPayments.{Error, OutgoingPayment}
  alias OpenPayments.Types.OutgoingPayment, as: PaymentData
  alias OpenPaymentsSnippets.Config

  @spec get(String.t(), keyword()) ::
          {:ok, PaymentData.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      OutgoingPayment.get(client, url, access_token: token)
    end
  end
end
