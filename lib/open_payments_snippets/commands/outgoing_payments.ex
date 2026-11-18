defmodule OpenPaymentsSnippets.Commands.OutgoingPayments do
  @moduledoc false

  alias OpenPayments.{Error, OutgoingPayment, WalletAddress}
  alias OpenPayments.Types.{CreateOutgoingPayment, OutgoingPaymentWithSpentAmounts}
  alias OpenPayments.Types.OutgoingPayment, as: PaymentData
  alias OpenPaymentsSnippets.{Config, Input}

  @spec get(String.t(), keyword()) ::
          {:ok, PaymentData.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      OutgoingPayment.get(client, url, access_token: token)
    end
  end

  @spec create(String.t() | nil, keyword()) ::
          {:ok, OutgoingPaymentWithSpentAmounts.t()} | {:error, Error.t() | String.t()}
  def create(source, options) do
    with {:ok, data} <- Input.json(source, "outgoing-payment request"),
         {:ok, request} <- CreateOutgoingPayment.from_map(data),
         {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options),
         {:ok, wallet} <- WalletAddress.get(client, request.wallet_address) do
      OutgoingPayment.create(client, wallet.resource_server, request, access_token: token)
    else
      {:error, %Error{operation: nil} = error} ->
        {:error, %{error | operation: :create_outgoing_payment}}

      {:error, error} ->
        {:error, error}
    end
  end
end
