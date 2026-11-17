defmodule OpenPaymentsSnippets.CLI do
  @moduledoc """
  Command-line entry point for the Open Payments SDK examples.

  `run/1` writes results to stdout, diagnostics to stderr, and returns an exit
  status. `main/1` is the escript entry point and terminates the VM with that status.
  """

  alias OpenPayments.{Client, Error, IncomingPayment, WalletAddress}
  alias OpenPayments.Types.{JWKS, PublicIncomingPayment}

  @help """
  Usage: open-payments [command] [options]

  Commands:
    help                Show this help
    version             Show CLI, SDK, and Open Payments specification versions
    wallet get [address] Fetch public wallet information using a URL or payment pointer
    wallet keys [address] Fetch the wallet's public JSON Web Key Set
    incoming get-public <url> Fetch public incoming-payment details

  Options:
    -h, --help          Show help
    -v, --version       Show version information
    --json              Format results as JSON
    --allow-http        Allow HTTP development URLs for resource commands

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

        options[:version] && is_tuple(command) ->
          argument_error("The --version option cannot be combined with resource commands.")

        Keyword.has_key?(options, :allow_http) && not is_tuple(command) ->
          argument_error("The --allow-http option requires a resource command.")

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
  defp command(["incoming", "get-public"]), do: {:ok, {:incoming, :get_public, nil}}
  defp command(["incoming", "get-public", url]), do: {:ok, {:incoming, :get_public, url}}
  defp command(_arguments), do: {:error, "Unknown command or unexpected arguments."}

  defp execute(:default, options) do
    command = if options[:version], do: :version, else: :help
    execute(command, options)
  end

  defp execute(:help, options), do: print_help(Keyword.get(options, :json, false))
  defp execute(:version, options), do: print_version(Keyword.get(options, :json, false))

  defp execute({:wallet, operation, address}, options) do
    get_resource(operation, address || System.get_env("WALLET_ADDRESS"), options)
  end

  defp execute({:incoming, :get_public, url}, options),
    do: get_resource(:get_public, url, options)

  defp print_help(true), do: argument_error("The --json option requires a result command.")

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

  defp get_resource(:get_public, url, _options) when url in [nil, ""] do
    argument_error("Supply a full incoming-payment URL.")
  end

  defp get_resource(_operation, address, _options) when address in [nil, ""] do
    argument_error("Supply a wallet address or set WALLET_ADDRESS.")
  end

  defp get_resource(operation, address, options) do
    with {:ok, client} <- Client.new_public(allow_http: Keyword.get(options, :allow_http, false)),
         {:ok, resource} <- fetch_resource(client, operation, address) do
      IO.puts(format_resource(resource, Keyword.get(options, :json, false)))
      0
    else
      {:error, %Error{kind: kind} = error} when kind in [:validation, :configuration] ->
        argument_error(resource_error(error))

      {:error, %Error{} = error} ->
        IO.puts(:stderr, "Error: #{resource_error(error)}")
        1
    end
  end

  defp fetch_resource(client, :get, address), do: WalletAddress.get(client, address)
  defp fetch_resource(client, :keys, address), do: WalletAddress.get_keys(client, address)
  defp fetch_resource(client, :get_public, url), do: IncomingPayment.get_public(client, url)

  defp format_resource(%PublicIncomingPayment{} = payment, json?) do
    payment
    |> PublicIncomingPayment.to_map()
    |> redact_shared_secrets()
    |> Jason.encode!(pretty: not json?)
  end

  defp format_resource(resource, true), do: Jason.encode!(resource)
  defp format_resource(%JWKS{} = keys, false), do: Jason.encode!(keys, pretty: true)

  defp format_resource(wallet, false) do
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

  defp redact_shared_secrets(data) when is_map(data) do
    Map.new(data, fn
      {"sharedSecret", _value} -> {"sharedSecret", "[REDACTED]"}
      {key, value} -> {key, redact_shared_secrets(value)}
    end)
  end

  defp redact_shared_secrets(data) when is_list(data),
    do: Enum.map(data, &redact_shared_secrets/1)

  defp redact_shared_secrets(value), do: value

  defp resource_error(%Error{kind: :validation, operation: :get_public_incoming_payment}) do
    "Invalid incoming-payment URL. Use a full HTTPS resource URL; local HTTP requires --allow-http."
  end

  defp resource_error(%Error{kind: :validation}) do
    "Invalid wallet address. Use an HTTPS URL or payment pointer; local HTTP requires --allow-http."
  end

  defp resource_error(%Error{kind: :configuration}),
    do: "Invalid Open Payments client configuration."

  defp resource_error(%Error{kind: :http, status: status} = error),
    do: "#{resource_label(error)} failed (HTTP #{status})."

  defp resource_error(%Error{kind: :transport} = error),
    do: "#{resource_label(error)} failed due to a transport error."

  defp resource_error(%Error{kind: :decoding} = error),
    do: "#{resource_label(error)} returned an invalid response."

  defp resource_label(%Error{operation: :get_public_incoming_payment}),
    do: "Incoming-payment read"

  defp resource_label(_error), do: "Wallet discovery"

  defp argument_error(message) do
    IO.puts(:stderr, "Error: #{message}\nRun open-payments help for usage.")
    2
  end
end
