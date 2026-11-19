defmodule OpenPaymentsSnippets.Commands.PaymentPreparation do
  @moduledoc false

  alias OpenPayments.{Error, IncomingPayment}
  alias OpenPayments.Types.{AccessToken, CreateIncomingPayment, IncomingPaymentWithMethods}
  alias OpenPayments.Types.WalletAddress, as: WalletData
  alias OpenPaymentsSnippets.GrantSession

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, payment, request, receiver} <- payment(session),
           {:ok, client, _key} <- GrantSession.client(session, options) do
        case payment["stage"] do
          "incoming-ready" -> cached(path, payment)
          "receiver-grant" -> prepare(path, session, client, response, request, receiver)
        end
      end
    end)
  end

  defp payment(session) do
    with %{"version" => 1, "stage" => stage} = payment <- session["payment"],
         true <- stage in ["receiver-grant", "incoming-ready"],
         {:ok, _sender} <- WalletData.from_map(payment["sender_wallet"]),
         {:ok, receiver} <- WalletData.from_map(payment["receiver_wallet"]),
         {:ok, request} <- CreateIncomingPayment.from_map(payment["incoming_request"]),
         true <- not is_nil(request.incoming_amount),
         true <- request.wallet_address == receiver.id,
         true <- session["grant_endpoint"] == receiver.auth_server,
         true <- stage != "receiver-grant" or not Map.has_key?(payment, "incoming_payment") do
      {:ok, payment, request, receiver}
    else
      _ -> invalid("Invalid payment context. Use a session created by payment start.")
    end
  end

  defp cached(path, payment) do
    case IncomingPaymentWithMethods.from_map(payment["incoming_payment"]) do
      {:ok, incoming} -> {:ok, summary(path, incoming, false)}
      _ -> invalid("Invalid saved incoming payment. Reconcile the session before continuing.")
    end
  end

  defp prepare(path, session, client, response, request, receiver) do
    case response.access_token do
      %AccessToken{} = token ->
        attempt(path, session, client, token, request, receiver)

      _ ->
        invalid("No issued receiver token. Use grant continue to complete authorization first.")
    end
  end

  defp attempt(path, session, client, token, request, receiver) do
    marked =
      Map.merge(session, %{
        "state" => "in-flight",
        "attempted_at" => now(),
        "attempt_operation" => "payment-prepare"
      })

    with :ok <- GrantSession.save(path, marked) do
      case IncomingPayment.create(client, receiver.resource_server, request, access_token: token) do
        {:ok, incoming} ->
          updated =
            session
            |> put_in(["payment", "stage"], "incoming-ready")
            |> put_in(
              ["payment", "incoming_payment"],
              IncomingPaymentWithMethods.to_map(incoming)
            )
            |> put_in(["payment", "incoming_created_at"], now())
            |> Map.put("state", "ready")
            |> Map.drop(~w(attempted_at attempt_operation))

          with :ok <- GrantSession.save(path, updated),
               do: {:ok, summary(path, incoming, true)}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp summary(path, incoming, saved?) do
    %{
      status: "ready",
      stage: "incoming-ready",
      saved: saved?,
      session: path,
      incoming_payment_url: incoming.id
    }
  end

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do: invalid("Invalid saved incoming-payment request, resource server or credential.")

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign payment preparation; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Payment preparation failed (HTTP #{status}). Session marked uncertain; reconcile before continuing."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Payment preparation failed or returned an invalid response. Session marked uncertain; an incoming payment may have been created. No automatic retry was made."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
