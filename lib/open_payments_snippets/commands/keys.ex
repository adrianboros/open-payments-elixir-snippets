defmodule OpenPaymentsSnippets.Commands.Keys do
  @moduledoc false

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.{JWK, JWKS}
  alias OpenPaymentsSnippets.Environment

  @spec validate(keyword()) :: {:ok, %{valid: true, key_id: String.t()}} | {:error, String.t()}
  def validate(options) do
    with {:ok, key} <- load(options),
         do: {:ok, %{valid: true, key_id: Key.key_id(key)}}
  end

  @spec public(keyword()) :: {:ok, JWK.t() | JWKS.t()} | {:error, String.t()}
  def public(options) do
    with {:ok, key} <- load(options) do
      public =
        if Keyword.get(options, :jwks, false), do: Key.public_jwks(key), else: Key.public_jwk(key)

      {:ok, public}
    end
  end

  @spec load(keyword()) :: {:ok, Key.t()} | {:error, String.t()}
  def load(options) do
    with {:ok, key_id} <- key_id(options),
         {:ok, source} <- key_source(options),
         {:ok, key} <- import_key(source, key_id) do
      {:ok, key}
    else
      {:error, %Error{}} ->
        {:error, "Invalid signing key. Check the key source, PEM format, and key ID."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp key_id(options) do
    case Keyword.get(options, :key_id, Environment.get(options, "KEY_ID")) do
      nil -> {:error, "Supply --key-id or set KEY_ID."}
      value -> {:ok, value}
    end
  end

  defp key_source(options) do
    case Keyword.fetch(options, :key_file) do
      {:ok, path} -> {:ok, {:file, path}}
      :error -> environment_source(options)
    end
  end

  defp environment_source(options) do
    case {Environment.get(options, "PRIVATE_KEY_FILE", ""),
          Environment.get(options, "PRIVATE_KEY_BASE64", "")} do
      {"", ""} ->
        {:error, "Supply --key-file or set PRIVATE_KEY_FILE or PRIVATE_KEY_BASE64."}

      {path, ""} ->
        {:ok, {:file, path}}

      {"", encoded} ->
        {:ok, {:base64_pem, encoded}}

      {_path, _encoded} ->
        {:error, "Set only one of PRIVATE_KEY_FILE and PRIVATE_KEY_BASE64."}
    end
  end

  defp import_key({:file, path}, key_id), do: Key.from_file(path, key_id)
  defp import_key({:base64_pem, encoded}, key_id), do: Key.from_base64_pem(encoded, key_id)
end
