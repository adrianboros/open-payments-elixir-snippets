defmodule OpenPaymentsSnippets.Commands.GrantContinuation do
  @moduledoc false

  alias OpenPayments.{Error, Grant, Key}
  alias OpenPayments.Types.{GrantContinuationResponse, JWK}
  alias OpenPaymentsSnippets.{GrantCallback, GrantSession}

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, received} <- GrantSession.validate(session),
           {:ok, client, key} <- GrantSession.client(session, options),
           :ok <- ready_time(response.continue.wait, received),
           {:ok, payload, verified?} <- GrantCallback.payload(session, response, options) do
        attempt(path, session, client, key, response.continue, payload, verified?)
      else
        {:waiting, seconds} -> {:ok, %{status: "waiting", wait_seconds: seconds, saved: false}}
        error -> error
      end
    end)
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
            |> Map.drop(
              ~w(attempted_at token_rotated_at token_rotation_response token_revoked_at)
            )

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
