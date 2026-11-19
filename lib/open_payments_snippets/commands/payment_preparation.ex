defmodule OpenPaymentsSnippets.Commands.PaymentPreparation do
  @moduledoc false

  alias OpenPayments.{Error, IncomingPayment}
  alias OpenPayments.Types.{AccessToken, IncomingPaymentWithMethods}
  alias OpenPaymentsSnippets.{GrantSession, PaymentSession}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, payment, request, _sender, receiver} <- PaymentSession.context(session),
           {:ok, client, _key} <- GrantSession.client(session, options) do
        case payment["stage"] do
          "receiver-grant" -> prepare(path, session, client, response, request, receiver)
          _ -> cached(path, payment)
        end
      end
    end)
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
