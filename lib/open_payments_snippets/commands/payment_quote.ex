defmodule OpenPaymentsSnippets.Commands.PaymentQuote do
  @moduledoc false

  alias OpenPayments.{Error, Quote}
  alias OpenPayments.Types.{AccessToken, Amount, CreateQuote, IncomingPaymentWithMethods}
  alias OpenPayments.Types.Quote, as: QuoteData
  alias OpenPaymentsSnippets.{GrantSession, PaymentSession}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, payment, request, sender, _receiver} <- PaymentSession.context(session),
           :ok <- stage(payment),
           {:ok, client, _key} <- GrantSession.client(session, options) do
        if payment["stage"] == "quote-ready" do
          cached(path, payment)
        else
          prepare(path, session, client, response.access_token, request, sender)
        end
      end
    end)
  end

  defp stage(%{"stage" => "quote-ready"}), do: :ok

  defp stage(%{"stage" => "sender-grant"} = payment) do
    if Map.has_key?(payment, "quote"),
      do: invalid("A quote is already recorded. Reconcile the session before continuing."),
      else: :ok
  end

  defp stage(_payment),
    do: invalid("Use payment authorize and complete sender authorization before quoting.")

  defp cached(path, payment) do
    case QuoteData.from_map(payment["quote"]) do
      {:ok, quote} -> {:ok, summary(path, quote, false)}
      _ -> invalid("Invalid saved quote. Reconcile the session before continuing.")
    end
  end

  defp prepare(path, session, client, %AccessToken{} = token, incoming_request, sender) do
    with {:ok, incoming} <-
           IncomingPaymentWithMethods.from_map(session["payment"]["incoming_payment"]),
         {:ok, request} <-
           CreateQuote.from_map(%{
             "walletAddress" => sender.id,
             "receiver" => incoming.id,
             "method" => "ilp",
             "receiveAmount" => Amount.to_map(incoming_request.incoming_amount)
           }) do
      attempt(path, session, client, token, sender.resource_server, request)
    else
      {:error, %Error{}} -> invalid("Invalid saved incoming payment or quote request.")
    end
  end

  defp prepare(_path, _session, _client, _token, _request, _sender),
    do: invalid("No issued sender token. Use grant continue to complete authorization first.")

  defp attempt(path, session, client, token, endpoint, request) do
    marked =
      Map.merge(session, %{
        "state" => "in-flight",
        "attempted_at" => now(),
        "attempt_operation" => "payment-quote"
      })

    with :ok <- GrantSession.save(path, marked) do
      case Quote.create(client, endpoint, request, access_token: token) do
        {:ok, quote} ->
          updated =
            session
            |> put_in(["payment", "stage"], "quote-ready")
            |> put_in(["payment", "quote"], QuoteData.to_map(quote))
            |> put_in(["payment", "quote_created_at"], now())
            |> Map.put("state", "ready")
            |> Map.drop(~w(attempted_at attempt_operation))

          with :ok <- GrantSession.save(path, updated),
               do: {:ok, summary(path, quote, true)}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp summary(path, quote, saved?) do
    %{
      status: "ready",
      stage: "quote-ready",
      saved: saved?,
      session: path,
      quote_url: quote.id,
      debit_amount:
        quote.debit_amount |> Amount.to_map() |> Map.take(~w(value assetCode assetScale)),
      receive_amount:
        quote.receive_amount |> Amount.to_map() |> Map.take(~w(value assetCode assetScale))
    }
  end

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do: invalid("Invalid saved quote request, resource server or sender credential.")

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign payment quote; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Payment quote failed (HTTP #{status}). Session marked uncertain; reconcile before continuing."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Payment quote failed or returned an invalid response. Session marked uncertain; a quote may have been created. No automatic retry was made."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
