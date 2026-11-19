defmodule OpenPaymentsSnippets.Commands.IncomingPayments do
  @moduledoc false

  alias OpenPayments.{Client, Error, IncomingPayment, WalletAddress}

  alias OpenPayments.Types.{
    CreateIncomingPayment,
    IncomingPaymentPaginationResult,
    IncomingPaymentWithMethods
  }

  alias OpenPayments.Types.IncomingPayment, as: IncomingPaymentData
  alias OpenPaymentsSnippets.{Config, Input, PaginationOptions}

  @spec get(String.t(), keyword()) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      IncomingPayment.get(client, url, access_token: token)
    end
  end

  @spec complete(String.t(), keyword()) ::
          {:ok, IncomingPaymentData.t()} | {:error, Error.t() | String.t()}
  def complete(url, options) do
    with {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      IncomingPayment.complete(client, url, access_token: token)
    end
  end

  @spec list(String.t() | nil, keyword()) ::
          {:ok, IncomingPaymentPaginationResult.t()} | {:error, Error.t() | String.t()}
  def list(address, options) do
    with {:ok, pagination} <- PaginationOptions.parse(options),
         {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options),
         {:ok, wallet} <- WalletAddress.get(client, address || Client.wallet_address(client)) do
      IncomingPayment.list(
        client,
        wallet.resource_server,
        wallet.id,
        [access_token: token] ++ pagination
      )
    else
      {:error, %Error{operation: nil} = error} ->
        {:error, %{error | operation: :list_incoming_payments}}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec create(String.t() | nil, keyword()) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t() | String.t()}
  def create(source, options) do
    with {:ok, data} <- Input.json(source, "incoming-payment request", options),
         {:ok, request} <- CreateIncomingPayment.from_map(data),
         {:ok, token} <- Config.access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options),
         {:ok, wallet} <- WalletAddress.get(client, request.wallet_address) do
      IncomingPayment.create(client, wallet.resource_server, request, access_token: token)
    else
      {:error, %Error{operation: nil} = error} ->
        {:error, %{error | operation: :create_incoming_payment}}

      {:error, error} ->
        {:error, error}
    end
  end
end
