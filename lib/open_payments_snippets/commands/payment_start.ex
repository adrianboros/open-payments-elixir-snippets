defmodule OpenPaymentsSnippets.Commands.PaymentStart do
  @moduledoc false

  alias OpenPayments.{Client, Error, Grant, Key, PaymentPointer, WalletAddress}

  alias OpenPayments.Types.{
    CreateIncomingPayment,
    GrantRequest,
    GrantResponse,
    InteractionFinish,
    JWK
  }

  alias OpenPayments.Types.WalletAddress, as: WalletData
  alias OpenPaymentsSnippets.{Config, GrantSession, Input, PaymentMetadata}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(source, options) do
    with {:ok, _output} <- output(options[:output]),
         {:ok, data} <- Input.json(source, "payment request", options) do
      from_map(data, options)
    else
      {:error, message} -> invalid(message)
    end
  end

  @spec from_map(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_map(data, options) do
    with {:ok, output} <- output(options[:output]),
         {:ok, incoming, finish, sender_address} <- intent(data),
         incoming = PaymentMetadata.annotate(incoming, options, "payment-quote"),
         {:ok, client, key} <- Config.authenticated_client(options) do
      GrantSession.create(output, fn path ->
        discover(path, client, key, incoming, finish, sender_address, options[:scenario])
      end)
    else
      {:error, message} -> invalid(message)
    end
  end

  defp output(path) when is_binary(path) and path not in ["", "-"], do: {:ok, path}
  defp output(_path), do: {:error, "Supply --output with a new private payment-session path."}

  defp intent(data) when is_map(data) do
    with true <-
           map_size(Map.drop(data, ~w(sender receiver receiveAmount finishUri metadata))) == 0,
         {:ok, sender} <- sender_address(data),
         receiver when is_binary(receiver) and receiver != "" <- data["receiver"],
         {:ok, receiver} <- receiver_url(receiver),
         true <- Map.has_key?(data, "receiveAmount"),
         {:ok, incoming} <- CreateIncomingPayment.from_map(incoming_map(data, receiver)),
         {:ok, finish} <-
           InteractionFinish.from_map(%{
             "method" => "redirect",
             "uri" => data["finishUri"],
             "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
           }) do
      {:ok, incoming, finish, sender}
    else
      _ ->
        {:error,
         "Invalid payment request. Supply receiver, receiveAmount, finishUri and optional metadata."}
    end
  end

  defp intent(_data), do: {:error, "Payment request must be a JSON object."}
  defp receiver_url("$" <> _ = pointer), do: PaymentPointer.to_url(pointer)
  defp receiver_url(url), do: {:ok, url}

  defp sender_address(data) do
    case Map.fetch(data, "sender") do
      :error -> {:ok, nil}
      {:ok, address} when is_binary(address) and address != "" -> receiver_url(address)
      _ -> {:error, :sender}
    end
  end

  defp incoming_map(data, receiver) do
    request = %{"walletAddress" => receiver, "incomingAmount" => data["receiveAmount"]}

    if Map.has_key?(data, "metadata"),
      do: Map.put(request, "metadata", data["metadata"]),
      else: request
  end

  defp discover(path, client, key, incoming, finish, sender_address, scenario) do
    with {:ok, sender} <-
           WalletAddress.get(client, sender_address || Client.wallet_address(client)),
         {:ok, receiver} <- WalletAddress.get(client, incoming.wallet_address),
         {:ok, request} <-
           GrantRequest.from_map(%{
             "client" => Client.wallet_address(client),
             "access_token" => %{
               "access" => [
                 %{
                   "type" => "incoming-payment",
                   "actions" => ["create", "read"],
                   "identifier" => receiver.id
                 }
               ]
             },
             "interact" => %{
               "start" => ["redirect"],
               "finish" => InteractionFinish.to_map(finish)
             }
           }) do
      session = %{
        "version" => 1,
        "kind" => "grant-request",
        "state" => "in-flight",
        "wallet_address" => Client.wallet_address(client),
        "key_id" => Key.key_id(key),
        "signing_jwk" => JWK.to_map(Key.public_jwk(key)),
        "grant_endpoint" => receiver.auth_server,
        "received_at" => now(),
        "attempted_at" => now(),
        "attempt_operation" => "payment-start",
        "callback_verified" => false,
        "finish" => InteractionFinish.to_map(finish),
        "payment" => %{
          "version" => 1,
          "stage" => "receiver-grant",
          "incoming_request" =>
            CreateIncomingPayment.to_map(%{incoming | wallet_address: receiver.id}),
          "sender_wallet" => WalletData.to_map(sender),
          "receiver_wallet" => WalletData.to_map(receiver)
        }
      }

      session = if scenario, do: put_in(session, ["payment", "scenario"], scenario), else: session
      request(path, client, request, session)
    else
      {:error, %Error{} = error} ->
        File.rm(path)
        sdk_error(error, "Payment wallet discovery")
    end
  end

  defp request(path, client, request, session) do
    with :ok <- GrantSession.save(path, session) do
      case Grant.request(client, session["grant_endpoint"], request) do
        {:ok, response} ->
          updated =
            session
            |> Map.merge(%{
              "state" => "ready",
              "received_at" => now(),
              "response" => GrantResponse.to_map(response)
            })
            |> Map.drop(~w(attempted_at attempt_operation))

          with :ok <- GrantSession.save(path, updated), do: {:ok, summary(path, response)}

        {:error, %Error{kind: kind} = error} ->
          if kind in [:validation, :configuration, :signing] do
            File.rm(path)
            sdk_error(error, "Payment authorization")
          else
            with :ok <- GrantSession.save(path, Map.put(session, "state", "uncertain")),
                 do: sdk_error(error, "Payment authorization; session marked uncertain")
          end
      end
    end
  end

  defp summary(path, response) do
    result = %{
      status: if(GrantResponse.pending?(response), do: "pending", else: "approved"),
      stage: "receiver-grant",
      saved: true,
      session: path
    }

    if response.interact,
      do: Map.put(result, :consent_url, response.interact.redirect),
      else: result
  end

  defp sdk_error(%Error{kind: kind}, _label) when kind in [:validation, :configuration],
    do: invalid("Invalid payment wallet, authorization endpoint or signing configuration.")

  defp sdk_error(%Error{kind: :http, status: status}, label),
    do: {:error, {:operation, "#{label} failed (HTTP #{status}). No automatic retry was made."}}

  defp sdk_error(%Error{}, label),
    do:
      {:error,
       {:operation,
        "#{label} failed or returned an invalid response. Reconcile any recorded attempt before retrying."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
