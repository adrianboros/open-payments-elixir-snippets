defmodule OpenPaymentsSnippets.Commands.IncomingPayments do
  @moduledoc false

  alias OpenPayments.{Error, IncomingPayment}
  alias OpenPayments.Types.IncomingPaymentWithMethods
  alias OpenPaymentsSnippets.Config

  @spec get(String.t(), keyword()) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t() | String.t()}
  def get(url, options) do
    with {:ok, token} <- access_token(options),
         {:ok, client, _key} <- Config.authenticated_client(options) do
      IncomingPayment.get(client, url, access_token: token)
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
