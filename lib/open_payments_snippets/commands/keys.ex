defmodule OpenPaymentsSnippets.Commands.Keys do
  @moduledoc false

  alias OpenPayments.{Error, Key}

  @spec validate(keyword()) :: {:ok, %{valid: true, key_id: String.t()}} | {:error, String.t()}
  def validate(options) do
    with {:ok, key_id} <- key_id(options),
         {:ok, source} <- key_source(options),
         {:ok, key} <- import_key(source, key_id) do
      {:ok, %{valid: true, key_id: Key.key_id(key)}}
    else
      {:error, %Error{}} ->
        {:error, "Invalid signing key. Check the key source, PEM format, and key ID."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp key_id(options) do
    case Keyword.get(options, :key_id, System.get_env("KEY_ID")) do
      nil -> {:error, "Supply --key-id or set KEY_ID."}
      value -> {:ok, value}
    end
  end

  defp key_source(options) do
    case Keyword.fetch(options, :key_file) do
      {:ok, path} -> {:ok, {:file, path}}
      :error -> environment_source()
    end
  end

  defp environment_source do
    case {System.get_env("PRIVATE_KEY_FILE", ""), System.get_env("PRIVATE_KEY_BASE64", "")} do
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
