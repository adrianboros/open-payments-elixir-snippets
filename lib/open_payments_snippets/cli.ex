defmodule OpenPaymentsSnippets.CLI do
  @moduledoc """
  Command-line entry point for the Open Payments SDK examples.

  `run/1` writes results to stdout, diagnostics to stderr, and returns an exit
  status. `main/1` is the escript entry point and terminates the VM with that status.
  """

  alias OpenPayments.{Client, Error, WalletAddress}
  alias OpenPayments.Types.JWKS

  @help """
  Usage: open-payments [command] [options]

  Commands:
    help                Show this help
    version             Show CLI, SDK, and Open Payments specification versions
    wallet get [address] Fetch public wallet information using a URL or payment pointer
    wallet keys [address] Fetch the wallet's public JSON Web Key Set

  Options:
    -h, --help          Show help
    -v, --version       Show version information
    --json              Format results as JSON
    --allow-http        Allow HTTP development URLs for wallet commands

  Wallet address defaults to the WALLET_ADDRESS environment variable.

  Exit statuses:
    0  Success
    1  Operation or runtime failure
    2  Invalid arguments or configuration
  """

  @doc "Runs the executable and exits with the command's status."
  @spec main([String.t()]) :: no_return()
  def main(argv), do: System.halt(run(argv))

  @doc "Runs a command without terminating the calling process."
  @spec run([String.t()]) :: 0 | 1 | 2
  def run(argv) do
    {options, arguments, invalid} =
      OptionParser.parse(argv,
        strict: [help: :boolean, version: :boolean, json: :boolean, allow_http: :boolean],
        aliases: [h: :help, v: :version]
      )

    with [] <- invalid,
         {:ok, command} <- command(arguments) do
      cond do
        (options[:help] && options[:version]) || (command == :help && options[:version]) ->
          argument_error("Choose either help or version.")

        options[:version] && match?({:wallet, _, _}, command) ->
          argument_error("The --version option cannot be combined with wallet commands.")

        Keyword.has_key?(options, :allow_http) && not match?({:wallet, _, _}, command) ->
          argument_error("The --allow-http option requires wallet get or wallet keys.")

        options[:help] ->
          print_help(Keyword.get(options, :json, false))

        true ->
          execute(command, options)
      end
    else
      [_ | _] -> argument_error("Unknown option or invalid option value.")
      {:error, message} -> argument_error(message)
    end
  end

  defp command([]), do: {:ok, :default}
  defp command(["help"]), do: {:ok, :help}
  defp command(["version"]), do: {:ok, :version}
  defp command(["wallet", "get"]), do: {:ok, {:wallet, :get, nil}}
  defp command(["wallet", "get", address]), do: {:ok, {:wallet, :get, address}}
  defp command(["wallet", "keys"]), do: {:ok, {:wallet, :keys, nil}}
  defp command(["wallet", "keys", address]), do: {:ok, {:wallet, :keys, address}}
  defp command(_arguments), do: {:error, "Unknown command or unexpected arguments."}

  defp execute(:default, options) do
    command = if options[:version], do: :version, else: :help
    execute(command, options)
  end

  defp execute(:help, options), do: print_help(Keyword.get(options, :json, false))
  defp execute(:version, options), do: print_version(Keyword.get(options, :json, false))

  defp execute({:wallet, operation, address}, options) do
    get_wallet(operation, address || System.get_env("WALLET_ADDRESS"), options)
  end

  defp print_help(true),
    do: argument_error("The --json option requires version, wallet get, or wallet keys.")

  defp print_help(false) do
    IO.write(@help)
    0
  end

  defp print_version(json?) do
    versions = %{
      cli_version: application_version(:open_payments_elixir_snippets),
      sdk_version: application_version(:open_payments_elixir),
      specification_version: OpenPayments.specification_version(),
      specification_revision: OpenPayments.Specification.revision()
    }

    IO.puts(format_versions(versions, json?))
    0
  end

  defp format_versions(versions, true), do: Jason.encode!(versions)

  defp format_versions(versions, false) do
    """
    open-payments #{versions.cli_version}
    SDK #{versions.sdk_version}
    Open Payments specification #{versions.specification_version}
    Specification revision #{versions.specification_revision}
    """
    |> String.trim_trailing()
  end

  defp application_version(application) do
    application |> Application.spec(:vsn) |> to_string()
  end

  defp get_wallet(_operation, address, _options) when address in [nil, ""] do
    argument_error("Supply a wallet address or set WALLET_ADDRESS.")
  end

  defp get_wallet(operation, address, options) do
    with {:ok, client} <- Client.new_public(allow_http: Keyword.get(options, :allow_http, false)),
         {:ok, resource} <- fetch_wallet(client, operation, address) do
      IO.puts(format_wallet(resource, Keyword.get(options, :json, false)))
      0
    else
      {:error, %Error{kind: kind} = error} when kind in [:validation, :configuration] ->
        argument_error(wallet_error(error))

      {:error, %Error{} = error} ->
        IO.puts(:stderr, "Error: #{wallet_error(error)}")
        1
    end
  end

  defp fetch_wallet(client, :get, address), do: WalletAddress.get(client, address)
  defp fetch_wallet(client, :keys, address), do: WalletAddress.get_keys(client, address)

  defp format_wallet(wallet, true), do: Jason.encode!(wallet)
  defp format_wallet(%JWKS{} = keys, false), do: Jason.encode!(keys, pretty: true)

  defp format_wallet(wallet, false) do
    [
      {"Wallet address", wallet.id},
      {"Public name", wallet.public_name},
      {"Asset", "#{wallet.asset_code} (scale #{wallet.asset_scale})"},
      {"Authorization server", wallet.auth_server},
      {"Resource server", wallet.resource_server}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map_join("\n", fn {label, value} -> "#{label}  #{value}" end)
  end

  defp wallet_error(%Error{kind: :validation}) do
    "Invalid wallet address. Use an HTTPS URL or payment pointer; local HTTP requires --allow-http."
  end

  defp wallet_error(%Error{kind: :configuration}), do: "Invalid wallet client configuration."

  defp wallet_error(%Error{kind: :http, status: status}),
    do: "Wallet discovery failed (HTTP #{status})."

  defp wallet_error(%Error{kind: :transport}),
    do: "Wallet discovery failed due to a transport error."

  defp wallet_error(%Error{kind: :decoding}),
    do: "Wallet discovery returned an invalid response."

  defp argument_error(message) do
    IO.puts(:stderr, "Error: #{message}\nRun open-payments help for usage.")
    2
  end
end
