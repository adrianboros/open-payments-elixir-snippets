defmodule OpenPaymentsSnippets.Commands.PaymentAuthorization do
  @moduledoc false

  alias OpenPayments.{Client, Error, Grant}

  alias OpenPayments.Types.{
    Amount,
    GrantRequest,
    GrantResponse,
    IncomingPaymentWithMethods,
    InteractionFinish
  }

  alias OpenPaymentsSnippets.{GrantSession, Input, PaymentSession}

  @spec run(String.t() | nil, String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, _source, _options) when path in [nil, ""],
    do: invalid("Supply a private payment-session file.")

  def run(path, source, options) do
    with {:ok, data} <- Input.json(source, "sender authorization"),
         {:ok, intent, finish} <- intent(data) do
      GrantSession.transaction(path, fn path, session ->
        with {:ok, response, _received} <- GrantSession.validate(session),
             {:ok, payment, _request, sender, _receiver} <- PaymentSession.context(session),
             {:ok, incoming} <- incoming(payment),
             {:ok, client, _key} <- GrantSession.client(session, options) do
          if payment["stage"] in ["sender-grant", "quote-ready"] do
            if payment["sender_authorization"] == intent,
              do: {:ok, summary(path, session, response, false)},
              else: invalid("Sender authorization is already recorded with different input.")
          else
            request(path, session, client, sender, incoming, intent, finish)
          end
        end
      end)
    else
      {:error, message} -> invalid(message)
    end
  end

  defp intent(data) when is_map(data) do
    with true <- map_size(Map.drop(data, ~w(debitAmount finishUri))) == 0,
         {:ok, amount} <- Amount.from_map(data["debitAmount"]),
         {:ok, finish} <-
           InteractionFinish.from_map(%{
             "method" => "redirect",
             "uri" => data["finishUri"],
             "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
           }) do
      {:ok, %{"debitAmount" => Amount.to_map(amount), "finishUri" => finish.uri}, finish}
    else
      _ -> {:error, "Invalid sender authorization. Supply debitAmount and finishUri only."}
    end
  end

  defp intent(_data), do: {:error, "Sender authorization must be a JSON object."}

  defp incoming(%{"stage" => stage} = payment)
       when stage in ["incoming-ready", "sender-grant", "quote-ready"] do
    case IncomingPaymentWithMethods.from_map(payment["incoming_payment"]) do
      {:ok, incoming} -> {:ok, incoming}
      _ -> invalid("Invalid saved incoming payment. Reconcile the session before continuing.")
    end
  end

  defp incoming(_payment),
    do: invalid("Use payment prepare to create the incoming payment first.")

  defp request(path, session, client, sender, incoming, intent, finish) do
    case GrantRequest.from_map(%{
           "client" => Client.wallet_address(client),
           "access_token" => %{
             "access" => [
               %{"type" => "quote", "actions" => ["create", "read"]},
               %{
                 "type" => "outgoing-payment",
                 "actions" => ["create", "read"],
                 "identifier" => sender.id,
                 "limits" => %{"debitAmount" => intent["debitAmount"], "receiver" => incoming.id}
               }
             ]
           },
           "interact" => %{"start" => ["redirect"], "finish" => InteractionFinish.to_map(finish)}
         }) do
      {:ok, request} ->
        attempt(path, session, client, sender.auth_server, request, intent, finish)

      {:error, %Error{}} ->
        invalid("Invalid sender authorization or saved incoming-payment URL.")
    end
  end

  defp attempt(path, session, client, endpoint, request, intent, finish) do
    payment =
      session["payment"]
      |> Map.put("stage", "sender-grant")
      |> Map.put("receiver_grant", Map.delete(session, "payment"))
      |> Map.put("sender_authorization", intent)

    marked =
      session
      |> Map.take(~w(version wallet_address key_id signing_jwk))
      |> Map.merge(%{
        "kind" => "grant-request",
        "state" => "in-flight",
        "grant_endpoint" => endpoint,
        "received_at" => now(),
        "attempted_at" => now(),
        "attempt_operation" => "payment-authorize",
        "callback_verified" => false,
        "finish" => InteractionFinish.to_map(finish),
        "payment" => payment
      })

    with :ok <- GrantSession.save(path, marked) do
      case Grant.request(client, endpoint, request) do
        {:ok, response} ->
          updated =
            marked
            |> Map.merge(%{
              "state" => "ready",
              "received_at" => now(),
              "response" => GrantResponse.to_map(response)
            })
            |> Map.drop(~w(attempted_at attempt_operation))

          with :ok <- GrantSession.save(path, updated),
               do: {:ok, summary(path, updated, response, true)}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp summary(path, session, response, saved?) do
    status =
      cond do
        session["kind"] == "token-revocation" -> "revoked"
        response.access_token -> "approved"
        true -> "pending"
      end

    result = %{status: status, stage: "sender-grant", saved: saved?, session: path}

    case Map.get(response, :interact) do
      %{redirect: url} when is_binary(url) -> Map.put(result, :consent_url, url)
      _ -> result
    end
  end

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do: invalid("Invalid sender authorization endpoint or signing configuration.")

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign sender authorization; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Sender authorization failed (HTTP #{status}). Session marked uncertain; reconcile before continuing."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Sender authorization failed or returned an invalid response. Session marked uncertain; a sender grant may have been created. No automatic retry was made."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
