defmodule OpenPaymentsSnippets.Commands.GrantCancellation do
  @moduledoc false

  alias OpenPayments.{Error, Grant, Key}
  alias OpenPayments.Types.JWK
  alias OpenPaymentsSnippets.GrantSession

  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, options) do
    GrantSession.transaction(path, fn path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, client, key} <- GrantSession.client(session, options) do
        attempt(path, session, client, key, response.continue)
      end
    end)
  end

  defp attempt(path, session, client, key, continuation) do
    marked =
      Map.merge(session, %{
        "state" => "in-flight",
        "attempted_at" => now(),
        "attempt_operation" => "cancel"
      })

    with :ok <- GrantSession.save(path, marked) do
      case Grant.cancel(client, continuation) do
        :ok ->
          cancelled =
            session
            |> Map.take(~w(version wallet_address key_id grant_endpoint))
            |> Map.merge(%{
              "kind" => "grant-cancellation",
              "state" => "cancelled",
              "cancelled_at" => now(),
              "signing_jwk" => JWK.to_map(Key.public_jwk(key))
            })

          with :ok <- GrantSession.save(path, cancelled),
               do: {:ok, %{status: "cancelled", saved: true}}

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
    do: {:error, {:argument, "Invalid continuation URL, credential or signing configuration."}}

  defp sdk_error(%Error{kind: :signing}),
    do: {:error, {:operation, "Unable to sign grant cancellation; no request was sent."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do:
      {:error,
       {:operation,
        "Grant cancellation failed (HTTP #{status}). Session marked uncertain; reconcile before another operation."}}

  defp sdk_error(%Error{}),
    do:
      {:error,
       {:operation,
        "Grant cancellation failed or returned an unexpected response. Session marked uncertain; the grant may have been cancelled. No automatic retry was made."}}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
