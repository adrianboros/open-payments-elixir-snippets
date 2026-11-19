defmodule OpenPaymentsSnippets.Environment do
  @moduledoc false

  @name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @credentials ~w(PRIVATE_KEY PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 ACCESS_TOKEN WALLET_KEY WALLET_SECRET)

  def prepare(options) do
    with {:ok, file} <- load_files(Keyword.get_values(options, :env_file)),
         {:ok, variables} <- variables(Keyword.get_values(options, :var)) do
      {:ok,
       options
       |> Keyword.put(:environment, Map.merge(file, System.get_env()))
       |> Keyword.put(:variables, variables)}
    end
  end

  def get(options, name, default \\ nil) do
    case options[:environment] do
      nil -> System.get_env(name, default)
      values -> Map.get(values, name, default)
    end
  end

  def variable(options, name) do
    cond do
      not is_binary(name) or not Regex.match?(@name, name) ->
        {:error, "Template variable names must use letters, digits and underscores."}

      String.upcase(name) in @credentials ->
        {:error, "Signing credentials and access tokens cannot be used as template variables."}

      true ->
        case Map.get(options[:variables] || %{}, name, get(options, name)) do
          nil ->
            {:error, "Missing template variable #{name}. Set it in the environment or use --var."}

          value ->
            {:ok, value}
        end
    end
  end

  defp variables(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, values} ->
      case String.split(entry, "=", parts: 2) do
        [name, value] ->
          if Regex.match?(@name, name),
            do: {:cont, {:ok, Map.put(values, name, value)}},
            else: {:halt, {:error, "Use --var NAME=value with a valid variable name."}}

        _ ->
          {:halt, {:error, "Use --var NAME=value with a valid variable name."}}
      end
    end)
  end

  defp load_files(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, values} ->
      case load(path) do
        {:ok, file} -> {:cont, {:ok, Map.merge(values, file)}}
        error -> {:halt, error}
      end
    end)
  end

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.valid?(contents),
          do: parse(contents),
          else: {:error, "Environment file must contain UTF-8 text."}

      {:error, _} ->
        {:error, "Unable to read environment file."}
    end
  end

  defp parse(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, values} ->
      case assignment(String.trim(line)) do
        :skip -> {:cont, {:ok, values}}
        {:ok, name, value} -> {:cont, {:ok, Map.put(values, name, value)}}
        :error -> {:halt, {:error, "Invalid environment assignment on line #{number}."}}
      end
    end)
  end

  defp assignment(""), do: :skip
  defp assignment("#" <> _comment), do: :skip

  defp assignment(line) do
    case Regex.run(~r/\A(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)\z/, line) do
      [_, name, value] ->
        case value(value) do
          {:ok, parsed} -> {:ok, name, parsed}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp value(<<quote, rest::binary>>) when quote in [?', ?"] do
    case String.split(rest, <<quote>>, parts: 2) do
      [literal, trailing] ->
        if String.trim(trailing) == "" or String.starts_with?(String.trim(trailing), "#"),
          do: {:ok, literal},
          else: :error

      _ ->
        :error
    end
  end

  defp value(literal),
    do: {:ok, literal |> String.split(~r/[ \t]+#/, parts: 2) |> hd() |> String.trim_trailing()}
end
