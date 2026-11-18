defmodule OpenPaymentsSnippets.Commands.Grants do
  @moduledoc false

  alias OpenPayments.{Client, Error, Grant, Key, WalletAddress}
  alias OpenPayments.Types.{GrantRequest, GrantResponse}
  alias OpenPaymentsSnippets.Commands.Keys

  @spec validate(String.t() | nil) :: {:ok, %{valid: true}} | {:error, String.t()}
  def validate(source) do
    with {:ok, _request} <- read_request(source) do
      {:ok, %{valid: true}}
    end
  end

  @spec request(String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, {:argument | :operation, String.t()}}
  def request(source, options) do
    with {:ok, output} <- output_path(options),
         {:ok, request} <- read_request(source),
         {:ok, key} <- Keys.load(options),
         {:ok, wallet} <- wallet_address(options),
         {:ok, client} <-
           Client.new_authenticated(
             wallet_address: wallet,
             key: key,
             allow_http: Keyword.get(options, :allow_http, false)
           ) do
      save_request(output, client, key, request)
    else
      {:error, %Error{}} ->
        {:error, {:argument, "Invalid wallet address or signing configuration."}}

      {:error, message} ->
        {:error, {:argument, message}}
    end
  end

  defp output_path(options) do
    case options[:output] do
      path when is_binary(path) and path not in ["", "-"] -> {:ok, path}
      _ -> {:error, "Supply --output with a new private grant-session file path."}
    end
  end

  defp wallet_address(options) do
    case Keyword.get(options, :wallet_address, System.get_env("WALLET_ADDRESS")) do
      value when value in [nil, ""] -> {:error, "Supply --wallet-address or set WALLET_ADDRESS."}
      value -> {:ok, value}
    end
  end

  defp save_request(path, client, key, request) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          try do
            with :ok <- private_file(path),
                 {:ok, wallet} <- WalletAddress.get(client, Client.wallet_address(client)),
                 {:ok, response} <- Grant.request(client, wallet.auth_server, request) do
              write_session(file, client, key, wallet.auth_server, request, response)
            end
          after
            File.close(file)
          end

        case result do
          {:ok, _summary} ->
            result

          {:error, %Error{} = error} ->
            File.rm(path)
            sdk_error(error)

          {:error, _reason} ->
            File.rm(path)
            result
        end

      {:error, _reason} ->
        {:error,
         {:operation,
          "Unable to create grant-session file. Use a new writable path; existing files are never overwritten."}}
    end
  end

  defp write_session(file, client, key, endpoint, request, response) do
    session = %{
      version: 1,
      kind: "grant-request",
      wallet_address: Client.wallet_address(client),
      key_id: Key.key_id(key),
      grant_endpoint: endpoint,
      received_at: DateTime.to_iso8601(DateTime.utc_now()),
      finish: if(request.interact, do: request.interact.finish),
      response: GrantResponse.to_map(response)
    }

    with :ok <- IO.binwrite(file, Jason.encode!(session, pretty: true) <> "\n"),
         :ok <- :file.sync(file) do
      {:ok,
       %{
         status: if(GrantResponse.pending?(response), do: "pending", else: "approved"),
         saved: true
       }}
    else
      _ -> save_error()
    end
  end

  defp private_file(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      _ -> {:error, {:operation, "Unable to protect grant-session file; no request was sent."}}
    end
  end

  defp save_error,
    do:
      {:error,
       {:operation,
        "Grant returned a response, but saving the session failed. Do not automatically repeat the request."}}

  defp sdk_error(%Error{kind: kind}) when kind in [:configuration, :validation],
    do:
      {:error,
       {:argument,
        "Invalid grant request, wallet address, authorization endpoint, or signing configuration."}}

  defp sdk_error(%Error{kind: :http, status: status}),
    do: {:error, {:operation, "Grant request or wallet discovery failed (HTTP #{status})."}}

  defp sdk_error(%Error{kind: :transport}),
    do:
      {:error,
       {:operation,
        "Grant request or wallet discovery failed due to a transport error. No automatic retry was made; the grant may have been created."}}

  defp sdk_error(%Error{kind: :decoding}),
    do:
      {:error,
       {:operation,
        "Grant request or wallet discovery returned an invalid response. No automatic retry was made; the grant may have been created."}}

  defp sdk_error(%Error{}),
    do: {:error, {:operation, "Grant request failed while signing the request."}}

  defp read_request(source) do
    with {:ok, json} <- read(source),
         {:ok, data} <- decode(json),
         {:ok, request} <- GrantRequest.from_map(data) do
      {:ok, request}
    else
      {:error, %Error{validation_errors: issues}} ->
        details =
          Enum.map(issues, fn %{field: field, message: message} -> "#{field}  #{message}" end)

        {:error, Enum.join(["Invalid grant request." | details], "\n")}

      {:error, message} ->
        {:error, message}
    end
  end

  defp read(source) when source in [nil, ""],
    do: {:error, "Supply a JSON file or - for stdin."}

  defp read("-") do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> {:error, "Unable to read grant request from stdin."}
      :eof -> {:ok, ""}
      data -> {:ok, data}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, "Unable to read grant request file."}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, data}
      {:error, _error} -> {:error, "Grant request must contain valid JSON."}
    end
  end
end
