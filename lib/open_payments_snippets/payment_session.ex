defmodule OpenPaymentsSnippets.PaymentSession do
  @moduledoc false

  alias OpenPayments.Types.CreateIncomingPayment
  alias OpenPayments.Types.WalletAddress, as: WalletData
  alias OpenPaymentsSnippets.GrantSession

  @spec context(map()) ::
          {:ok, map(), struct(), WalletData.t(), WalletData.t()} | {:error, term()}
  def context(session) do
    with %{"version" => 1, "stage" => stage} = payment <- session["payment"],
         true <-
           stage in [
             "receiver-grant",
             "incoming-ready",
             "sender-grant",
             "quote-ready",
             "outgoing-created"
           ],
         {:ok, sender} <- WalletData.from_map(payment["sender_wallet"]),
         {:ok, receiver} <- WalletData.from_map(payment["receiver_wallet"]),
         {:ok, request} <- CreateIncomingPayment.from_map(payment["incoming_request"]),
         true <- not is_nil(request.incoming_amount),
         true <- request.wallet_address == receiver.id,
         true <- stage != "receiver-grant" or not Map.has_key?(payment, "incoming_payment"),
         :ok <- active_grant(session, payment, sender, receiver) do
      {:ok, payment, request, sender, receiver}
    else
      _ ->
        {:error, {:argument, "Invalid payment context. Use a session created by payment start."}}
    end
  end

  defp active_grant(session, %{"stage" => stage} = payment, sender, receiver)
       when stage in ["sender-grant", "quote-ready", "outgoing-created"] do
    with true <- session["grant_endpoint"] == sender.auth_server,
         %{} = archived <- payment["receiver_grant"],
         {:ok, _response, _received} <- GrantSession.validate(archived),
         true <- archived["grant_endpoint"] == receiver.auth_server,
         true <-
           Map.take(archived, ~w(wallet_address key_id signing_jwk)) ==
             Map.take(session, ~w(wallet_address key_id signing_jwk)) do
      :ok
    else
      _ -> {:error, :context}
    end
  end

  defp active_grant(session, _payment, _sender, receiver) do
    if session["grant_endpoint"] == receiver.auth_server, do: :ok, else: {:error, :context}
  end
end
