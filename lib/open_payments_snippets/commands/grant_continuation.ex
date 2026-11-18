defmodule OpenPaymentsSnippets.Commands.GrantContinuation do
  @moduledoc false

  alias OpenPayments.{Client, Error, Grant, Key}
  alias OpenPayments.Types.{GrantContinuationResponse, GrantResponse, JWK}
  alias OpenPaymentsSnippets.{Config, GrantCallback, GrantSession}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, received} <- validate(session),
           {:ok, client, key} <- client(session, options),
           :ok <- ready_time(response.continue.wait, received),
           {:ok, payload, verified?} <- GrantCallback.payload(session, response, options) do
        attempt(path, session, client, key, response.continue, payload, verified?)
      else
        {:waiting, seconds} -> {:ok, %{status: "waiting", wait_seconds: seconds, saved: false}}
        error -> error
      end
    end)
  end

  defp validate(session) do
    with 1 <- session["version"],
         true <- not Map.has_key?(session, "state") or session["state"] == "ready",
         true <- is_binary(session["wallet_address"]) and is_binary(session["key_id"]),
         true <- is_binary(session["grant_endpoint"]),
         true <- is_binary(session["received_at"]),
         true <-
           not Map.has_key?(session, "callback_verified") or
             is_boolean(session["callback_verified"]),
         {:ok, received, _offset} <- DateTime.from_iso8601(session["received_at"]),
         true <- DateTime.compare(received, DateTime.utc_now()) != :gt,
         {:ok, response} <- decode_response(session) do
      {:ok, response, received}
    else
      _ ->
        invalid(
          "Invalid or unavailable grant session. Check its version, state, identity and receipt time; reconcile any interrupted attempt."
        )
    end
  end

  defp decode_response(%{"kind" => "grant-request", "response" => data}),
    do: GrantResponse.from_map(data)

  defp decode_response(%{"kind" => "grant-continuation", "response" => data}),
    do: GrantContinuationResponse.from_map(data)

  defp decode_response(_session), do: {:error, :kind}

  defp client(session, options) do
    options =
      options
      |> Keyword.put_new(:wallet_address, session["wallet_address"])
      |> Keyword.put_new(:key_id, session["key_id"])

    with {:ok, client, key} <- Config.authenticated_client(options),
         true <-
           Client.wallet_address(client) == session["wallet_address"] and
             Key.key_id(key) == session["key_id"],
         true <-
           is_nil(session["signing_jwk"]) or
             session["signing_jwk"] == JWK.to_map(Key.public_jwk(key)) do
      {:ok, client, key}
    else
      {:error, message} -> invalid(message)
      _ -> invalid("Signing identity does not match the grant session.")
    end
  end

  defp ready_time(wait, received) do
    remaining =
      max(wait || 0, 0) * 1_000_000 - DateTime.diff(DateTime.utc_now(), received, :microsecond)

    if remaining > 0, do: {:waiting, div(remaining + 999_999, 1_000_000)}, else: :ok
  end

  defp attempt(path, session, client, key, continuation, payload, verified?) do
    marked = session |> Map.put("state", "in-flight") |> Map.put("attempted_at", now())

    with :ok <- GrantSession.save(path, marked) do
      case Grant.continue(client, continuation, payload) do
        {:ok, response} ->
          updated =
            session
            |> Map.merge(%{
              "kind" => "grant-continuation",
              "state" => "ready",
              "received_at" => now(),
              "callback_verified" => verified?,
              "signing_jwk" => JWK.to_map(Key.public_jwk(key)),
              "response" => GrantContinuationResponse.to_map(response)
            })
            |> Map.delete("attempted_at")

          with :ok <- GrantSession.save(path, updated), do: {:ok, summary(response)}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp summary(response) do
    status =
      cond do
        GrantContinuationResponse.has_access_token?(response) -> "approved"
        GrantContinuationResponse.has_subject?(response) -> "subject"
        true -> "pending"
      end

    %{status: status, saved: true}
  end

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do: invalid("Invalid continuation URL, credential or signing configuration.")

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign grant continuation; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Grant continuation failed (HTTP #{status}). Session marked uncertain; reconcile before continuing."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Grant continuation failed or returned an invalid response. Session marked uncertain; the grant may have advanced. No automatic retry was made."}}

  defp invalid(message), do: {:error, {:argument, message}}
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
