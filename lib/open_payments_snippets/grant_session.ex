defmodule OpenPaymentsSnippets.GrantSession do
  @moduledoc false

  import Bitwise

  @spec transaction(String.t() | nil, function()) :: term()
  def transaction(path, _action) when path in [nil, ""],
    do: {:error, {:argument, "Supply a private grant-session file."}}

  def transaction(path, action) do
    path = Path.expand(path)
    lock_path = path <> ".lock"

    case File.open(lock_path, [:write, :binary, :exclusive]) do
      {:ok, lock} ->
        try do
          with :ok <- protect(lock_path),
               {:ok, session} <- load(path) do
            action.(path, session)
          end
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

  defp save_error,
    do:
      {:error,
       {:operation,
        "Unable to save private grant session. If an attempt was recorded, reconcile its outcome before continuing."}}
end
