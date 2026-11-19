defmodule OpenPaymentsSnippets.GrantSession do
  @moduledoc false

  import Bitwise

  alias OpenPayments.{Client, Key}
  alias OpenPayments.Types.{GrantContinuationResponse, GrantResponse, JWK}
  alias OpenPaymentsSnippets.Config

  @spec transaction(String.t() | nil, function()) :: term()
  def transaction(path, _action) when path in [nil, ""],
    do: {:error, {:argument, "Supply a private grant-session file."}}

  def transaction(path, action) do
    with_lock(path, fn path ->
      with {:ok, session} <- load(path), do: action.(path, session)
    end)
  end

  @spec create(String.t(), function()) :: term()
  def create(path, action) do
    with_lock(path, fn path ->
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, file} ->
          result =
            try do
              protect(path)
            after
              File.close(file)
            end

          case result do
            :ok ->
              action.(path)

            error ->
              File.rm(path)
              error
          end

        {:error, _reason} ->
          {:error,
           {:operation,
            "Unable to create private session. Use a new writable path; existing files are never overwritten."}}
      end
    end)
  end

  defp with_lock(path, action) do
    path = Path.expand(path)
    lock_path = path <> ".lock"

    case File.open(lock_path, [:write, :binary, :exclusive]) do
      {:ok, lock} ->
        try do
          with :ok <- protect(lock_path), do: action.(path)
        after
          File.close(lock)
          File.rm(lock_path)
        end

      {:error, _reason} ->
        {:error,
         {:operation,
          "Unable to lock grant session. Another command or an interrupted attempt may hold the lock; reconcile before removing it."}}
    end
  end

  @spec save(String.t(), map()) :: :ok | {:error, {:operation, String.t()}}
  def save(path, session) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    temporary = path <> ".tmp-" <> suffix

    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          result =
            try do
              with :ok <- protect(temporary),
                   :ok <- IO.binwrite(file, Jason.encode!(session, pretty: true) <> "\n"),
                   :ok <- :file.sync(file) do
                :ok
              end
            after
              File.close(file)
            end

          with :ok <- result,
               :ok <- File.rename(temporary, path) do
            :ok
          else
            _ -> save_error()
          end
        after
          File.rm(temporary)
        end

      {:error, _reason} ->
        save_error()
    end
  end

  @spec validate(map()) :: {:ok, struct(), DateTime.t()} | {:error, term()}
  def validate(session) do
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

  @spec client(map(), keyword()) :: {:ok, Client.t(), Key.t()} | {:error, term()}
  def client(session, options) do
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

  defp decode_response(%{"kind" => "grant-request", "response" => data}),
    do: GrantResponse.from_map(data)

  defp decode_response(%{"kind" => "grant-continuation", "response" => data}),
    do: GrantContinuationResponse.from_map(data)

  defp decode_response(%{"kind" => "token-revocation", "response" => data})
       when is_map(data) and not is_map_key(data, "access_token"),
       do: GrantContinuationResponse.from_map(data)

  defp decode_response(_session), do: {:error, :kind}

  defp load(path) do
    with {:ok, %{type: :regular, links: 1, mode: mode}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600,
         {:ok, json} <- File.read(path),
         {:ok, session} when is_map(session) <- Jason.decode(json) do
      {:ok, session}
    else
      _ ->
        {:error,
         {:argument,
          "Unable to read grant session. Use a regular JSON file with a single link and permissions 0600; symlinks and hard links are rejected."}}
    end
  end

  defp protect(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      _ -> save_error()
    end
  end

  defp invalid(message), do: {:error, {:argument, message}}

  defp save_error,
    do:
      {:error,
       {:operation,
        "Unable to save private grant session. If an attempt was recorded, reconcile its outcome before continuing."}}
end
