defmodule OpenPaymentsSnippets.Commands.IncomingPayments do
  @moduledoc false

  alias OpenPayments.{Client, Error, IncomingPayment, WalletAddress}

  alias OpenPayments.Types.{
    CreateIncomingPayment,
    IncomingPaymentPaginationResult,
    IncomingPaymentWithMethods,
    Pagination
  }

  alias OpenPayments.Types.IncomingPayment, as: IncomingPaymentData
  alias OpenPaymentsSnippets.{Config, Input}

  @spec get(String.t(), keyword()) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      IncomingPayment.get(client, url, access_token: token)
    end
  end

  @spec complete(String.t(), keyword()) ::
          {:ok, IncomingPaymentData.t()} | {:error, Error.t() | String.t()}
  def complete(url, options) do
    with {:ok, token} <- access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      IncomingPayment.complete(client, url, access_token: token)
    end
  end

  @spec list(String.t() | nil, keyword()) ::
          {:ok, IncomingPaymentPaginationResult.t()} | {:error, Error.t() | String.t()}
  def list(address, options) do
    with {:ok, pagination} <- pagination_options(options),
         {:ok, token} <- access_token(options),
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

  defp pagination_options(options) do
    data =
      for {key, value} <- Keyword.take(options, [:first, :last, :cursor]),
          into: %{},
          do: {Atom.to_string(key), value}

    if map_size(data) == 0 do
      {:ok, []}
    else
      with {:ok, pagination} <- Pagination.from_map(data), do: {:ok, [pagination: pagination]}
    end
  end

  @spec create(String.t() | nil, keyword()) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t() | String.t()}
  def create(source, options) do
    with {:ok, data} <- Input.json(source, "incoming-payment request"),
         {:ok, request} <- CreateIncomingPayment.from_map(data),
         {:ok, token} <- access_token(options),
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

  defp access_token(options) do
    case Keyword.fetch(options, :access_token_file) do
      {:ok, path} -> read_token(path)
      :error -> environment_token()
    end
  end

  defp environment_token do
    case System.get_env("ACCESS_TOKEN", "") do
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
