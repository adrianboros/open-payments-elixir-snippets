defmodule OpenPaymentsSnippets.CLI do
  @moduledoc """
  Command-line entry point for the Open Payments SDK examples.

  `run/1` writes results to stdout, diagnostics to stderr, and returns an exit
  status. `main/1` is the escript entry point and terminates the VM with that status.
  """

  alias OpenPayments.{Client, Error, IncomingPayment, PaymentPointer, WalletAddress}
  alias OpenPayments.Types.{IncomingPaymentWithMethods, JWKS, PublicIncomingPayment}
  alias OpenPaymentsSnippets.Commands.{Grants, IncomingPayments, Keys}

  @help """
  Usage: open-payments [command] [options]

  Commands:
    help                Show this help
    version             Show CLI, SDK, and Open Payments specification versions
    wallet get [address] Fetch public wallet information using a URL or payment pointer
    wallet keys [address] Fetch the wallet's public JSON Web Key Set
    incoming get-public <url> Fetch public incoming-payment details
    incoming get <url>   Fetch incoming-payment details with a signed resource-token request
    incoming create <file|-> Discover the receiving wallet and create an incoming payment
    keys validate       Validate an existing Ed25519 signing key offline
    keys public         Export the configured key's public JWK offline
    grant validate <file|-> Validate grant-request JSON offline
    grant request <file|-> Discover the auth server and request a signed grant
    pointer resolve <pointer> Convert a quoted payment pointer to a URL offline

  Options:
    -h, --help          Show help
    -v, --version       Show version information
    --json              Format results as JSON
    --allow-http        Allow HTTP development URLs for resource/grant requests
    --key-id <id>       Override KEY_ID for key commands or authenticated requests
    --key-file <path>   Select a PEM file for key commands or authenticated requests
    --jwks              Export a key set with keys public
    --wallet-address <address> Override WALLET_ADDRESS for authenticated requests
    --access-token-file <path> Read a resource token for incoming get/create, overriding ACCESS_TOKEN
    --output <path>     Save grant request state and secrets to a new private file

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
        strict: [
          help: :boolean,
          version: :boolean,
          json: :boolean,
          allow_http: :boolean,
          key_id: :string,
          key_file: :string,
          jwks: :boolean,
          wallet_address: :string,
          output: :string,
          access_token_file: :string
        ],
        aliases: [h: :help, v: :version]
      )

    with [] <- invalid,
         {:ok, command} <- command(arguments) do
      cond do
        (options[:help] && options[:version]) || (command == :help && options[:version]) ->
          argument_error("Choose either help or version.")

        options[:version] && is_tuple(command) ->
          argument_error("The --version option cannot be combined with another command.")

        Keyword.has_key?(options, :allow_http) && not resource_command?(command) ->
          argument_error("The --allow-http option requires a resource command.")

        (Keyword.has_key?(options, :key_id) || Keyword.has_key?(options, :key_file)) &&
            not signing_command?(command) ->
          argument_error(
            "Signing-key options require keys validate, keys public, grant request, incoming get, or incoming create."
          )

        Keyword.has_key?(options, :output) &&
            not match?({:grant, :request, _}, command) ->
          argument_error("The --output option requires grant request.")

        Keyword.has_key?(options, :wallet_address) && not authenticated_command?(command) ->
          argument_error(
            "The --wallet-address option requires grant request, incoming get, or incoming create."
          )

        Keyword.has_key?(options, :access_token_file) && not resource_token_command?(command) ->
          argument_error(
            "The --access-token-file option requires incoming get or incoming create."
          )

        Keyword.has_key?(options, :jwks) && command != {:keys, :public} ->
          argument_error("The --jwks option requires keys public.")

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
  defp command(["incoming", "get"]), do: {:ok, {:incoming, :get, nil}}
  defp command(["incoming", "get", url]), do: {:ok, {:incoming, :get, url}}
  defp command(["incoming", "create"]), do: {:ok, {:incoming, :create, nil}}
  defp command(["incoming", "create", source]), do: {:ok, {:incoming, :create, source}}
  defp command(["keys", "validate"]), do: {:ok, {:keys, :validate}}
  defp command(["keys", "public"]), do: {:ok, {:keys, :public}}
  defp command(["grant", "validate"]), do: {:ok, {:grant, :validate, nil}}
  defp command(["grant", "validate", source]), do: {:ok, {:grant, :validate, source}}
  defp command(["grant", "request"]), do: {:ok, {:grant, :request, nil}}
  defp command(["grant", "request", source]), do: {:ok, {:grant, :request, source}}
  defp command(["pointer", "resolve"]), do: {:ok, {:pointer, :resolve, nil}}
  defp command(["pointer", "resolve", pointer]), do: {:ok, {:pointer, :resolve, pointer}}
  defp command(_arguments), do: {:error, "Unknown command or unexpected arguments."}

  defp resource_command?({group, _operation, _target}) when group in [:wallet, :incoming],
    do: true

  defp resource_command?({:grant, :request, _}), do: true
  defp resource_command?(_command), do: false

  defp signing_command?({:keys, _}), do: true
  defp signing_command?(command), do: authenticated_command?(command)

  defp authenticated_command?({:grant, :request, _}), do: true
  defp authenticated_command?(command), do: resource_token_command?(command)

  defp resource_token_command?({:incoming, operation, _}) when operation in [:get, :create],
    do: true

  defp resource_token_command?(_command), do: false

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

  defp execute({:incoming, :get, url}, options),
    do: get_resource(:get_authenticated, url, options)

  defp execute({:incoming, :create, source}, options),
    do: print_resource_result(IncomingPayments.create(source, options), options)

  defp execute({:keys, operation}, options) do
    outcome =
      case operation do
        :validate -> Keys.validate(options)
        :public -> Keys.public(options)
      end

    case outcome do
      {:ok, result} ->
        IO.puts(format_key_result(result, Keyword.get(options, :json, false)))
        0

      {:error, message} ->
        argument_error(message)
    end
  end

  defp execute({:grant, :validate, source}, options) do
    case Grants.validate(source) do
      {:ok, result} ->
        output =
          if Keyword.get(options, :json, false),
            do: Jason.encode!(result),
            else: "Valid grant request"

        IO.puts(output)
        0

      {:error, message} ->
        argument_error(message)
    end
  end

  defp execute({:grant, :request, source}, options) do
    case Grants.request(source, options) do
      {:ok, result} ->
        output =
          if Keyword.get(options, :json, false),
            do: Jason.encode!(result),
            else: "Grant #{result.status}\nGrant session saved to the requested private file."

        IO.puts(output)
        0

      {:error, {:argument, message}} ->
        argument_error(message)

      {:error, {:operation, message}} ->
        IO.puts(:stderr, "Error: #{message}")
        1
    end
  end

  defp execute({:pointer, :resolve, pointer}, _options) when pointer in [nil, ""] do
    argument_error("Supply a payment pointer, quoted with single quotes.")
  end

  defp execute({:pointer, :resolve, pointer}, options) do
    case PaymentPointer.to_url(pointer) do
      {:ok, url} ->
        output = if Keyword.get(options, :json, false), do: Jason.encode!(%{url: url}), else: url
        IO.puts(output)
        0

      {:error, %Error{}} ->
        argument_error("Invalid payment pointer. Quote '$host[/path]' with single quotes.")
    end
  end

  defp format_key_result(%{valid: true} = result, false),
    do: "Valid Ed25519 signing key\nKey ID  #{result.key_id}"

  defp format_key_result(result, json?), do: Jason.encode!(result, pretty: not json?)

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

  defp get_resource(operation, url, _options)
       when operation in [:get_public, :get_authenticated] and url in [nil, ""] do
    argument_error("Supply a full incoming-payment URL.")
  end

  defp get_resource(_operation, address, _options) when address in [nil, ""] do
    argument_error("Supply a wallet address or set WALLET_ADDRESS.")
  end

  defp get_resource(operation, address, options) do
    print_resource_result(fetch_resource(operation, address, options), options)
  end

  defp print_resource_result(result, options) do
    case result do
      {:ok, resource} ->
        IO.puts(format_resource(resource, Keyword.get(options, :json, false)))
        0

      {:error, %Error{kind: kind} = error} when kind in [:validation, :configuration] ->
        argument_error(resource_error(error))

      {:error, %Error{} = error} ->
        IO.puts(:stderr, "Error: #{resource_error(error)}")
        1

      {:error, message} ->
        argument_error(message)
    end
  end

  defp fetch_resource(:get_authenticated, url, options), do: IncomingPayments.get(url, options)

  defp fetch_resource(operation, address, options) do
    with {:ok, client} <- Client.new_public(allow_http: Keyword.get(options, :allow_http, false)),
         do: fetch_public_resource(client, operation, address)
  end

  defp fetch_public_resource(client, :get, address), do: WalletAddress.get(client, address)
  defp fetch_public_resource(client, :keys, address), do: WalletAddress.get_keys(client, address)

  defp fetch_public_resource(client, :get_public, url),
    do: IncomingPayment.get_public(client, url)

  defp format_resource(%PublicIncomingPayment{} = payment, json?) do
    payment
    |> PublicIncomingPayment.to_map()
    |> redact_shared_secrets()
    |> Jason.encode!(pretty: not json?)
  end

  defp format_resource(%IncomingPaymentWithMethods{} = payment, json?) do
    payment
    |> IncomingPaymentWithMethods.to_map()
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

  defp resource_error(%Error{kind: :validation, operation: :get_incoming_payment}) do
    "Invalid incoming-payment URL or resource access token. Use a full HTTPS resource URL; local HTTP requires --allow-http."
  end

  defp resource_error(%Error{kind: :validation, operation: :create_incoming_payment}) do
    "Invalid incoming-payment request, resource-server URL, or resource access token."
  end

  defp resource_error(%Error{kind: :validation}) do
    "Invalid wallet address. Use an HTTPS URL or payment pointer; local HTTP requires --allow-http."
  end

  defp resource_error(%Error{kind: :configuration}),
    do: "Invalid Open Payments client configuration."

  defp resource_error(%Error{kind: :http, status: status} = error),
    do: "#{resource_label(error)} failed (HTTP #{status})."

  defp resource_error(%Error{kind: :transport, operation: :create_incoming_payment}),
    do:
      "Incoming-payment creation failed due to a transport error. No automatic retry was made; the payment may have been created."

  defp resource_error(%Error{kind: :decoding, operation: :create_incoming_payment}),
    do:
      "Incoming-payment creation returned an invalid response. No automatic retry was made; the payment may have been created."

  defp resource_error(%Error{kind: :transport} = error),
    do: "#{resource_label(error)} failed due to a transport error."

  defp resource_error(%Error{kind: :decoding} = error),
    do: "#{resource_label(error)} returned an invalid response."

  defp resource_error(%Error{kind: :signing}), do: "Unable to sign the incoming-payment request."

  defp resource_label(%Error{operation: :get_public_incoming_payment}),
    do: "Incoming-payment read"

  defp resource_label(%Error{operation: :get_incoming_payment}),
    do: "Authenticated incoming-payment read"

  defp resource_label(%Error{operation: :create_incoming_payment}),
    do: "Incoming-payment creation"

  defp resource_label(_error), do: "Wallet discovery"

  defp argument_error(message) do
    IO.puts(:stderr, "Error: #{message}\nRun open-payments help for usage.")
    2
  end
end
