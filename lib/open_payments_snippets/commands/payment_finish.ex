defmodule OpenPaymentsSnippets.Commands.PaymentFinish do
  @moduledoc false

  alias OpenPayments.{Error, OutgoingPayment}

  alias OpenPayments.Types.{
    AccessOutgoing,
    AccessToken,
    Amount,
    CreateOutgoingPayment,
    IncomingPaymentWithMethods,
    OutgoingPaymentWithSpentAmounts
  }

  alias OpenPayments.Types.Quote, as: QuoteData
  alias OpenPaymentsSnippets.{GrantSession, PaymentMetadata, PaymentSession}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, payment, _request, sender, _receiver} <- PaymentSession.context(session),
           :ok <- stage(payment),
           {:ok, client, _key} <- GrantSession.client(session, options) do
        if payment["stage"] == "outgoing-created" do
          cached(path, payment)
        else
          prepare(path, session, client, response.access_token, sender, options)
        end
      end
    end)
  end

  defp stage(%{"stage" => "outgoing-created"}), do: :ok

  defp stage(%{"stage" => "quote-ready"} = payment) do
    if Map.has_key?(payment, "outgoing_payment") or Map.has_key?(payment, "outgoing_request"),
      do: invalid("An outgoing attempt is already recorded. Reconcile before continuing."),
      else: :ok
  end

  defp stage(_payment), do: invalid("Use payment quote before finishing the payment.")

  defp cached(path, payment) do
    case OutgoingPaymentWithSpentAmounts.from_map(payment["outgoing_payment"]) do
      {:ok, outgoing} -> {:ok, summary(path, outgoing, false)}
      _ -> invalid("Invalid saved outgoing payment. Reconcile the session before continuing.")
    end
  end

  defp prepare(path, session, client, %AccessToken{} = token, sender, options) do
    payment = session["payment"]

    with {:ok, incoming} <- IncomingPaymentWithMethods.from_map(payment["incoming_payment"]),
         {:ok, quote} <- QuoteData.from_map(payment["quote"]),
         true <- quote.wallet_address == sender.id and quote.receiver == incoming.id,
         :ok <- authorized_quote(payment, token, quote, sender.id),
         {:ok, request} <-
           CreateOutgoingPayment.from_map(%{"walletAddress" => sender.id, "quoteId" => quote.id}),
         request = PaymentMetadata.outgoing(request, payment["incoming_request"], options),
         {:ok, confirmation} <- confirm(sender.id, incoming.id, quote, options) do
      if confirmation == :declined do
        {:ok, %{status: "declined", stage: "quote-ready", saved: false, session: path}}
      else
        attempt(path, session, client, token, sender.resource_server, request, confirmation)
      end
    else
      {:error, {:argument, _}} = error ->
        error

      _ ->
        invalid(
          "Invalid saved quote or incoming payment. Check its binding to the sender and receiver."
        )
    end
  end

  defp prepare(_path, _session, _client, _token, _sender, _options),
    do: invalid("No issued sender token. Complete sender authorization before finishing.")

  defp authorized_quote(payment, token, quote, sender_id) do
    with {:ok, maximum} <-
           Amount.from_map(get_in(payment, ["sender_authorization", "debitAmount"])) do
      cond do
        not within_limit?(quote.debit_amount, maximum) ->
          invalid(
            "Quote debit #{Jason.encode!(core(quote.debit_amount))} does not fit the requested maximum #{Jason.encode!(core(maximum))}. No outgoing request was sent; obtain a new authorization with a suitable limit."
          )

        not Enum.any?(token.access, &allows_quote?(&1, quote, sender_id)) ->
          invalid(
            "The issued token does not authorize this quote's sender, receiver or amounts. No outgoing request was sent; obtain a new authorization."
          )

        true ->
          :ok
      end
    else
      _ -> invalid("Invalid saved sender debit limit. No outgoing request was sent.")
    end
  end

  defp allows_quote?(
         %AccessOutgoing{identifier: sender_id, actions: actions, limits: limits},
         quote,
         sender_id
       ) do
    "create" in actions and
      (is_nil(limits) or
         ((is_nil(limits.receiver) or limits.receiver == quote.receiver) and
            within_limit?(quote.debit_amount, limits.debit_amount) and
            within_limit?(quote.receive_amount, limits.receive_amount)))
  end

  defp allows_quote?(_access, _quote, _sender_id), do: false

  defp within_limit?(_amount, nil), do: true

  defp within_limit?(amount, limit) do
    amount.asset_code == limit.asset_code and amount.asset_scale == limit.asset_scale and
      String.to_integer(amount.value) <= String.to_integer(limit.value)
  end

  defp confirm(sender, incoming, quote, options) do
    cond do
      options[:yes] == true -> {:ok, "yes"}
      options[:json] == true -> invalid("New payment creation with --json requires --yes.")
      true -> prompt(sender, incoming, quote)
    end
  end

  defp prompt(sender, incoming, quote) do
    IO.write(
      :stderr,
      Enum.join(
        [
          "Create outgoing payment from this saved quote?",
          "Sender  #{Jason.encode!(sender)}",
          "Incoming payment  #{Jason.encode!(incoming)}",
          "Quote  #{Jason.encode!(quote.id)}",
          "Debit amount  #{Jason.encode!(core(quote.debit_amount))}",
          "Receive amount  #{Jason.encode!(core(quote.receive_amount))}",
          "Quote expiry  #{Jason.encode!(quote.expires_at)}",
          "Type send to create the outgoing payment; any other input declines: "
        ],
        "\n"
      )
    )

    case IO.gets(:stdio, "") do
      answer when is_binary(answer) ->
        {:ok, if(String.trim(answer) == "send", do: "prompt", else: :declined)}

      _ ->
        {:ok, :declined}
    end
  end

  defp attempt(path, session, client, token, endpoint, request, confirmation) do
    marked =
      session
      |> Map.merge(%{
        "state" => "in-flight",
        "attempted_at" => now(),
        "attempt_operation" => "payment-finish"
      })
      |> put_in(["payment", "outgoing_request"], CreateOutgoingPayment.to_map(request))
      |> put_in(["payment", "outgoing_confirmed_at"], now())
      |> put_in(["payment", "outgoing_confirmation"], confirmation)

    with :ok <- GrantSession.save(path, marked) do
      case OutgoingPayment.create(client, endpoint, request, access_token: token) do
        {:ok, outgoing} ->
          updated =
            marked
            |> Map.put("state", "ready")
            |> Map.drop(~w(attempted_at attempt_operation))
            |> put_in(["payment", "stage"], "outgoing-created")
            |> put_in(
              ["payment", "outgoing_payment"],
              OutgoingPaymentWithSpentAmounts.to_map(outgoing)
            )
            |> put_in(["payment", "outgoing_created_at"], now())

          with :ok <- GrantSession.save(path, updated),
               do: {:ok, summary(path, outgoing, true)}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp summary(path, outgoing, saved?) do
    %{
      status: "created",
      stage: "outgoing-created",
      saved: saved?,
      session: path,
      outgoing_payment_url: outgoing.id,
      failed: outgoing.failed,
      debit_amount: core(outgoing.debit_amount),
      receive_amount: core(outgoing.receive_amount),
      sent_amount: core(outgoing.sent_amount)
    }
  end

  defp core(amount), do: amount |> Amount.to_map() |> Map.take(~w(value assetCode assetScale))

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do: invalid("Invalid saved outgoing request, resource server or sender credential.")

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign payment finish; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Payment finish failed (HTTP #{status}). Session marked uncertain; an outgoing payment may have been created or started. Reconcile before continuing."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Payment finish failed or returned an invalid response. Session marked uncertain; an outgoing payment may have been created or started. No automatic retry was made."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
