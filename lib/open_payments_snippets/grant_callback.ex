defmodule OpenPaymentsSnippets.GrantCallback do
  @moduledoc false

  alias OpenPayments.Interaction
  alias OpenPayments.Types.{GrantResponse, InteractionFinish}
  alias OpenPaymentsSnippets.GrantSession

  @spec verify(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def verify(path, options) do
    if Keyword.has_key?(options, :callback_file) do
      GrantSession.transaction(path, fn _path, session ->
        with {:ok, response, _received} <- GrantSession.validate(session),
             {:ok, _payload, true} <- payload(session, response, options) do
          {:ok, %{valid: true}}
        else
          {:ok, _, _} -> invalid("This session has no pending interaction callback to verify.")
          error -> error
        end
      end)
    else
      invalid("Supply --callback-file with the returned callback URL, or - for stdin.")
    end
  end

  @spec payload(map(), struct(), keyword()) :: {:ok, map() | nil, boolean()} | {:error, term()}
  def payload(session, response, options) do
    needed? =
      match?(%GrantResponse{interact: %{finish: _}}, response) and not is_nil(session["finish"])

    cond do
      session["callback_verified"] == true and Keyword.has_key?(options, :callback_file) ->
        invalid("This session's interaction callback has already been consumed.")

      not needed? and Keyword.has_key?(options, :callback_file) ->
        invalid("This session does not accept an interaction callback.")

      needed? ->
        verify(session, response, options)

      true ->
        {:ok, nil, session["callback_verified"] == true}
    end
  end

  defp verify(session, response, options) do
    with {:ok, encoding} <- encoding(Keyword.get(options, :hash_encoding, "base64")),
         {:ok, finish} <- InteractionFinish.from_map(session["finish"]),
         {:ok, returned} <- read(options[:callback_file]),
         {:ok, reference, hash} <- callback_values(finish.uri, returned),
         :ok <-
           Interaction.verify_hash(hash,
             client_nonce: finish.nonce,
             server_nonce: response.interact.finish,
             interact_ref: reference,
             grant_endpoint: session["grant_endpoint"],
             encoding: encoding
           ) do
      {:ok, %{"interact_ref" => reference}, true}
    else
      {:error, {:argument, _message}} = error ->
        error

      _ ->
        invalid(
          "Invalid interaction callback or hash. Check the saved context and selected hash encoding."
        )
    end
  end

  defp encoding("base64"), do: {:ok, :base64}
  defp encoding("base64url"), do: {:ok, :base64url}
  defp encoding(_value), do: invalid("Hash encoding must be base64 or base64url.")

  defp read(source) when source in [nil, ""],
    do: invalid("Supply --callback-file with the returned callback URL, or - for stdin.")

  defp read(source) do
    result =
      if source == "-" do
        case IO.read(:stdio, :eof) do
          data when is_binary(data) -> {:ok, data}
          _ -> {:error, :read}
        end
      else
        File.read(source)
      end

    case result do
      {:ok, value} ->
        if String.valid?(value),
          do: {:ok, String.trim(value)},
          else: invalid("Callback file must contain a UTF-8 URL.")

      _ ->
        invalid("Unable to read interaction callback.")
    end
  end

  defp callback_values(expected, returned) do
    with {:ok, original} <- parse_uri(expected),
         {:ok, actual} <- parse_uri(returned),
         :ok <-
           require_callback(
             %{original | query: nil} == %{actual | query: nil},
             "Callback destination does not match this session's finish URL. Use the return URL from the correct consent flow."
           ),
         {:ok, fixed} <- query(original.query),
         {:ok, values} <- query(actual.query),
         :ok <-
           require_callback(
             not Enum.any?(fixed, fn {name, _} ->
               name in ["hash", "interact_ref", "error", "result"]
             end),
             "The saved finish URL uses reserved callback parameters. Start a new grant with a clean finish URL."
           ),
         :ok <-
           require_callback(
             not Enum.any?(values, fn {name, _} -> name in ["error", "result"] end),
             "The callback reports an error or result instead of a successful interaction. No continuation was sent."
           ),
         {:ok, hash} <- single_parameter(values, "hash"),
         {:ok, reference} <- single_parameter(values, "interact_ref"),
         :ok <-
           require_callback(
             Enum.sort(Enum.reject(values, fn {name, _} -> name in ["hash", "interact_ref"] end)) ==
               Enum.sort(fixed),
             "Callback query parameters do not match this session. Check the payment direction and consent stage."
           ) do
      {:ok, reference, hash}
    else
      {:error, {:argument, _}} = error ->
        error

      {:error, :query} ->
        invalid("Callback query contains invalid percent encoding or UTF-8.")

      _ ->
        invalid("Callback must contain one complete, unbroken URL without quotes or extra text.")
    end
  end

  defp require_callback(true, _message), do: :ok
  defp require_callback(false, message), do: invalid(message)

  defp single_parameter(values, name) do
    case Enum.filter(values, fn {key, _} -> key == name end) do
      [{^name, value}] when value != "" ->
        {:ok, value}

      _ ->
        invalid(
          "Callback must contain exactly one nonempty hash and one interact_ref. Copy the full return URL."
        )
    end
  end

  defp parse_uri(value) when is_binary(value) do
    with true <- String.valid?(value),
         false <- Regex.match?(~r/[\x00-\x20\x7f]/, value),
         {:ok, %URI{scheme: scheme, userinfo: nil, fragment: nil} = uri} when is_binary(scheme) <-
           URI.new(value) do
      {:ok, uri}
    else
      _ -> {:error, :uri}
    end
  end

  defp parse_uri(_value), do: {:error, :uri}

  defp query(nil), do: {:ok, []}

  defp query(value) do
    if Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value) do
      {:error, :query}
    else
      pairs = Enum.to_list(URI.query_decoder(value))

      if Enum.all?(pairs, fn {key, value} -> String.valid?(key) and String.valid?(value) end),
        do: {:ok, pairs},
        else: {:error, :query}
    end
  rescue
    ArgumentError -> {:error, :query}
  end

  defp invalid(message), do: {:error, {:argument, message}}
end
