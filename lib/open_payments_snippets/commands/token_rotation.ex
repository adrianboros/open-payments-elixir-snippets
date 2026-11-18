defmodule OpenPaymentsSnippets.Commands.TokenRotation do
  @moduledoc false

  alias OpenPayments.{Error, Key, Token}
  alias OpenPayments.Types.{AccessToken, JWK, TokenRotationResponse}
  alias OpenPaymentsSnippets.GrantSession

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, token} <- issued_token(response.access_token),
           {:ok, client, key} <- GrantSession.client(session, options) do
        attempt(path, session, client, key, token)
      end
    end)
  end

  defp issued_token(%AccessToken{} = token), do: {:ok, token}

  defp issued_token(_token),
    do: {:error, {:argument, "The grant session has no issued access token to rotate."}}

  defp attempt(path, session, client, key, token) do
    marked =
      Map.merge(session, %{
        "state" => "in-flight",
        "attempted_at" => now(),
        "attempt_operation" => "token-rotate"
      })

    with :ok <- GrantSession.save(path, marked) do
      case Token.rotate(client, token) do
        {:ok, rotated} ->
          updated =
            session
            |> put_in(["response", "access_token"], AccessToken.to_map(rotated.access_token))
            |> Map.merge(%{
              "state" => "ready",
              "signing_jwk" => JWK.to_map(Key.public_jwk(key)),
              "token_rotated_at" => now(),
              "token_rotation_response" => TokenRotationResponse.to_map(rotated)
            })
            |> Map.drop(~w(attempted_at attempt_operation))

          with :ok <- GrantSession.save(path, updated),
               do: {:ok, %{status: "rotated", saved: true}}

        {:error, %Error{kind: kind} = error} ->
          retained =
            if kind in [:validation, :configuration, :signing],
              do: session,
              else: Map.put(marked, "state", "uncertain")

          with :ok <- GrantSession.save(path, retained), do: sdk_error(error)
      end
    end
  end

  defp sdk_error(%Error{kind: kind}) when kind in [:validation, :configuration],
    do:
      {:error, {:argument, "Invalid token management URL, credential or signing configuration."}}

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign token rotation; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Token rotation failed (HTTP #{status}). Session marked uncertain; reconcile before another operation."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Token rotation failed or returned an invalid response. Session marked uncertain; the token may have changed. No automatic retry was made."}}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
