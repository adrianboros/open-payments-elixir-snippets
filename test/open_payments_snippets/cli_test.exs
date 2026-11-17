defmodule OpenPaymentsSnippets.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.HTTPServer

  @wallet %{
    "id" => "https://wallet.example/accounts/alice",
    "publicName" => "Alice",
    "assetCode" => "USD",
    "assetScale" => 2,
    "authServer" => "https://auth.example/tenants/alice",
    "resourceServer" => "https://payments.example/tenants/alice"
  }

  # Public key from RFC 8032 test vector 1.
  @key %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }

  @incoming_payment %{
    "id" => "https://payments.example/tenant/incoming-payments/payment-1",
    "completed" => false,
    "receivedAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
    "createdAt" => "2026-11-17T09:20:50.52Z",
    "authServer" => "https://auth.example/tenant",
    "methods" => [
      %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
    ]
  }

  # PKCS#8 encoding of the public RFC 8032 section 7.1 test-1 seed, matching
  # the sibling SDK's Node-exported fixture. This is public test material.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """

  setup do
    names = ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 PRIVATE_KEY)
    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "no arguments, help command, and help flags show available commands" do
    for argv <- [[], ["help"], ["--help"], ["-h"], ["version", "--help"]] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""
      assert stdout =~ "Usage: open-payments"
      assert stdout =~ "help"
      assert stdout =~ "version"
      assert stdout =~ "--json"
      assert stdout =~ "0  Success"
      assert stdout =~ "1  Operation or runtime failure"
      assert stdout =~ "2  Invalid arguments or configuration"
    end
  end

  test "version command and flags report actual dependency metadata" do
    for argv <- [["version"], ["--version"], ["-v"]] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""

      assert stdout == """
             open-payments #{Application.spec(:open_payments_elixir_snippets, :vsn)}
             SDK #{Application.spec(:open_payments_elixir, :vsn)}
             Open Payments specification #{OpenPayments.specification_version()}
             Specification revision #{OpenPayments.Specification.revision()}
             """
    end
  end

  test "JSON version works before and after the command and with aliases" do
    for argv <- [
          ["version", "--json"],
          ["--json", "version"],
          ["--version", "--json"],
          ["--json", "-v"]
        ] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""

      assert Jason.decode!(stdout) == %{
               "cli_version" => to_string(Application.spec(:open_payments_elixir_snippets, :vsn)),
               "sdk_version" => to_string(Application.spec(:open_payments_elixir, :vsn)),
               "specification_version" => OpenPayments.specification_version(),
               "specification_revision" => OpenPayments.Specification.revision()
             }
    end
  end

  test "standard boolean negation and values control JSON output" do
    for argv <- [["version", "--no-json"], ["version", "--json=false"]] do
      {stdout, stderr, status} = invoke(argv)
      assert status == 0
      assert stderr == ""
      assert stdout =~ "open-payments "
    end

    {stdout, "", 0} = invoke(["version", "--json=true"])
    assert is_map(Jason.decode!(stdout))
  end

  test "unknown options and invalid option values fail even with help" do
    for argv <- [
          ["--unknown"],
          ["--help", "--unknown"],
          ["version", "--json=invalid"],
          ["--help=invalid"],
          ["--version=invalid"],
          ["version", "-j"]
        ] do
      assert_argument_error(argv, "Unknown option or invalid option value.")
    end
  end

  test "unknown commands, extra arguments, and missing future subcommands fail" do
    for argv <- [
          ["unknown"],
          ["version", "extra"],
          ["help", "extra"],
          ["pointer"],
          ["version", "--", "--json"],
          ["--help", "unknown"],
          ["--version", "unknown"]
        ] do
      assert_argument_error(argv, "Unknown command or unexpected arguments.")
    end
  end

  test "conflicting help and version requests fail" do
    for argv <- [["--help", "--version"], ["help", "--version"]] do
      assert_argument_error(argv, "Choose either help or version.")
    end
  end

  test "JSON requires a result command" do
    for argv <- [["--json"], ["help", "--json"], ["--help", "--json"]] do
      assert_argument_error(
        argv,
        "The --json option requires a result command."
      )
    end
  end

  test "diagnostics omit supplied argument and option values" do
    for argv <- [
          ["sensitive-input"],
          ["--unknown=sensitive-input"],
          ["version", "--json=sensitive-input"]
        ] do
      {"", stderr, 2} = invoke(argv)
      refute stderr =~ "sensitive-input"
      assert stderr =~ "Error:"
    end
  end

  test "wallet get uses the SDK over HTTP and displays public wallet fields" do
    base = HTTPServer.start({200, [{"content-type", "application/json"}], Jason.encode!(@wallet)})
    {stdout, stderr, status} = invoke(["wallet", "get", base <> "/tenant/alice", "--allow-http"])

    assert status == 0
    assert stderr == ""
    assert stdout =~ "Wallet address  #{@wallet["id"]}"
    assert stdout =~ "Public name  Alice"
    assert stdout =~ "Asset  USD (scale 2)"
    assert stdout =~ "Authorization server  #{@wallet["authServer"]}"
    assert stdout =~ "Resource server  #{@wallet["resourceServer"]}"
    assert_received {:http_request, %{method: :GET, target: "/tenant/alice", headers: headers}}
    assert headers["accept"] == "application/json"
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "authorization")
  end

  test "wallet JSON preserves SDK field mappings, extensions, and returned URLs" do
    response = Map.put(@wallet, "custom", %{"enabled" => true})
    base = HTTPServer.start({200, [], Jason.encode!(response)})

    {stdout, stderr, status} =
      invoke(["--json", "wallet", "get", base <> "/alice", "--allow-http"])

    assert status == 0
    assert stderr == ""
    assert Jason.decode!(stdout) == response
    assert_received {:http_request, %{target: "/alice"}}
  end

  test "wallet get reads WALLET_ADDRESS and an explicit address takes precedence" do
    base = HTTPServer.start({200, [], Jason.encode!(@wallet)})
    System.put_env("WALLET_ADDRESS", base <> "/default-wallet")

    assert {_stdout, "", 0} = invoke(["wallet", "get", "--allow-http"])
    assert_received {:http_request, %{target: "/default-wallet"}}

    assert {_stdout, "", 0} = invoke(["wallet", "get", base <> "/explicit", "--allow-http"])
    assert_received {:http_request, %{target: "/explicit"}}
  end

  test "missing wallet settings and malformed commands fail before any request" do
    base = HTTPServer.start({200, [], Jason.encode!(@wallet)})

    for argv <- [["wallet", "get"], ["wallet", "get", ""]] do
      assert_argument_error(argv, "Supply a wallet address or set WALLET_ADDRESS.")
    end

    for argv <- [
          ["wallet"],
          ["wallet", "unknown"],
          ["wallet", "get", base, "extra"],
          ["wallet", "get", base, "--allow-http=invalid"],
          ["wallet", "get", base, "--allow-http", "--unknown"]
        ] do
      assert {"", _stderr, 2} = invoke(argv)
    end

    refute_received {:http_request, _}
  end

  test "SDK rejects invalid identifiers and HTTP without explicit opt-in before requesting" do
    base = HTTPServer.start({200, [], Jason.encode!(@wallet)})

    for address <- [base <> "/alice", "not-a-wallet", "$wallet.example/alice?secret", " "] do
      assert_argument_error(
        ["wallet", "get", address],
        "Invalid wallet address. Use an HTTPS URL or payment pointer; local HTTP requires --allow-http."
      )
    end

    assert {"", _stderr, 2} = invoke(["wallet", "get", base, "--no-allow-http"])
    refute_received {:http_request, _}
  end

  test "wallet help makes no request and wallet-only options have command scope" do
    base = HTTPServer.start({200, [], Jason.encode!(@wallet)})

    for argv <- [
          ["wallet", "get", "--help"],
          ["wallet", "get", base, "--help", "--allow-http"]
        ] do
      {stdout, "", 0} = invoke(argv)
      assert stdout =~ "wallet get"
    end

    for argv <- [["version", "--allow-http"], ["help", "--allow-http"]] do
      assert_argument_error(argv, "The --allow-http option requires a resource command.")
    end

    assert_argument_error(
      ["wallet", "get", base, "--version"],
      "The --version option cannot be combined with another command."
    )

    refute_received {:http_request, _}
  end

  test "HTTP failures and redirects return status 1 and omit server error contents" do
    for status <- [302, 404, 500] do
      body = Jason.encode!(%{"error" => %{"code" => "private-value", "description" => "secret"}})
      base = HTTPServer.start({status, [{"location", "/elsewhere"}], body})
      {"", stderr, 1} = invoke(["wallet", "get", base <> "/alice", "--allow-http", "--json"])
      assert stderr == "Error: Wallet discovery failed (HTTP #{status}).\n"
      assert_received {:http_request, %{target: "/alice"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "malformed and schema-invalid wallet responses return status 1" do
    for body <- ["not-json", "{}", Jason.encode!(Map.put(@wallet, "assetScale", 256))] do
      base = HTTPServer.start({200, [], body})
      {"", stderr, 1} = invoke(["wallet", "get", base <> "/alice", "--allow-http"])
      assert stderr == "Error: Wallet discovery returned an invalid response.\n"
      assert_received {:http_request, _}
      stop_supervised!(Task)
    end
  end

  test "transport failures return status 1 without retrying" do
    base = HTTPServer.start(:close)
    {"", stderr, 1} = invoke(["wallet", "get", base <> "/alice", "--allow-http"])
    assert stderr == "Error: Wallet discovery failed due to a transport error.\n"
    assert_received {:http_request, _}
    refute_receive {:http_request, _}, 20
  end

  test "wallet keys fetches unsigned public JWKS and supports readable and compact JSON" do
    key = Map.merge(@key, %{"use" => "sig", "custom" => %{"enabled" => true}})
    response = %{"keys" => [key]}
    base = HTTPServer.start({200, [], Jason.encode!(response)})

    for options <- [[], ["--json"]] do
      {stdout, stderr, status} =
        invoke(["wallet", "keys", base <> "/tenant/alice", "--allow-http"] ++ options)

      assert status == 0
      assert stderr == ""
      assert Jason.decode!(stdout) == response
      assert String.contains?(String.trim_trailing(stdout), "\n") == (options == [])

      assert_received {:http_request,
                       %{method: :GET, target: "/tenant/alice/jwks.json", headers: headers}}

      assert headers["accept"] == "application/json"
      refute Map.has_key?(headers, "signature")
      refute Map.has_key?(headers, "authorization")
    end
  end

  test "wallet keys delegates encoded and trailing path handling to the SDK" do
    base = HTTPServer.start({200, [], ~s({"keys":[]})})

    for path <- ["/tenant/a%2Fb", "/tenant/a%2Fb/"] do
      assert {stdout, "", 0} =
               invoke(["wallet", "keys", base <> path, "--allow-http", "--json"])

      assert Jason.decode!(stdout) == %{"keys" => []}
      assert_received {:http_request, %{target: "/tenant/a%2Fb/jwks.json"}}
    end
  end

  test "wallet keys uses WALLET_ADDRESS with explicit argument precedence" do
    base = HTTPServer.start({200, [], Jason.encode!(%{"keys" => [@key, @key]})})
    System.put_env("WALLET_ADDRESS", base <> "/default-wallet")

    assert {stdout, "", 0} = invoke(["wallet", "keys", "--allow-http", "--json"])
    assert Jason.decode!(stdout) == %{"keys" => [@key, @key]}
    assert_received {:http_request, %{target: "/default-wallet/jwks.json"}}

    assert {_stdout, "", 0} = invoke(["wallet", "keys", base <> "/explicit", "--allow-http"])
    assert_received {:http_request, %{target: "/explicit/jwks.json"}}
  end

  test "wallet keys rejects missing settings, invalid identifiers and arguments before requests" do
    base = HTTPServer.start({200, [], ~s({"keys":[]})})

    for argv <- [["wallet", "keys"], ["wallet", "keys", ""]] do
      assert_argument_error(argv, "Supply a wallet address or set WALLET_ADDRESS.")
    end

    for address <- [base, "not-a-wallet", "$wallet.example/alice?private-value"] do
      assert_argument_error(
        ["wallet", "keys", address],
        "Invalid wallet address. Use an HTTPS URL or payment pointer; local HTTP requires --allow-http."
      )
    end

    for arguments <- [["extra"], ["--unknown"], ["--allow-http=invalid"]] do
      assert {"", _stderr, 2} = invoke(["wallet", "keys", base] ++ arguments)
    end

    assert_argument_error(
      ["wallet", "keys", base, "--version"],
      "The --version option cannot be combined with another command."
    )

    refute_received {:http_request, _}
  end

  test "wallet keys help avoids requests" do
    base = HTTPServer.start({200, [], ~s({"keys":[]})})
    System.put_env("WALLET_ADDRESS", base)

    for arguments <- [[], [base, "--allow-http"]] do
      assert {stdout, "", 0} = invoke(["wallet", "keys", "--help"] ++ arguments)
      assert stdout =~ "wallet keys [address]"
    end

    refute_received {:http_request, _}
  end

  test "wallet keys rejects malformed, schema-invalid and private responses without exposing data" do
    private_key = Map.put(@key, "d", "private-key-material")

    for body <- [
          "not-json",
          "{}",
          Jason.encode!(%{"keys" => [Map.delete(@key, "alg")]}),
          Jason.encode!(%{"keys" => [private_key]})
        ] do
      base = HTTPServer.start({200, [], body})

      for options <- [[], ["--json"]] do
        assert {"", stderr, 1} =
                 invoke(["wallet", "keys", base <> "/alice", "--allow-http"] ++ options)

        assert stderr == "Error: Wallet discovery returned an invalid response.\n"
        assert_received {:http_request, %{target: "/alice/jwks.json"}}
      end

      stop_supervised!(Task)
    end
  end

  test "wallet keys reports HTTP failures and redirects with safe diagnostics" do
    for status <- [302, 404, 500] do
      body = Jason.encode!(%{"error" => %{"description" => "private-value"}})
      base = HTTPServer.start({status, [{"location", "/other-keys"}], body})

      assert {"", stderr, 1} =
               invoke(["wallet", "keys", base <> "/alice", "--allow-http", "--json"])

      assert stderr == "Error: Wallet discovery failed (HTTP #{status}).\n"
      assert_received {:http_request, %{target: "/alice/jwks.json"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "wallet keys reports transport failures without retrying" do
    base = HTTPServer.start(:close)
    assert {"", stderr, 1} = invoke(["wallet", "keys", base <> "/alice", "--allow-http"])
    assert stderr == "Error: Wallet discovery failed due to a transport error.\n"
    assert_received {:http_request, %{target: "/alice/jwks.json"}}
    refute_receive {:http_request, _}, 20
  end

  test "public incoming reads use unsigned GET and preserve opaque paths and queries" do
    base = HTTPServer.start({200, [], Jason.encode!(@incoming_payment)})
    target = "/tenant/opaque%2Fresource/../payment?part=a%2Bb&part=second"

    assert {stdout, "", 0} =
             invoke(["incoming", "get-public", base <> target, "--allow-http", "--json"])

    output = Jason.decode!(stdout)
    assert Map.drop(output, ["methods"]) == Map.drop(@incoming_payment, ["methods"])

    assert output["methods"] == [
             %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "[REDACTED]"}
           ]

    refute stdout =~ "test-secret"
    assert_received {:http_request, %{method: :GET, target: ^target, headers: headers}}
    assert headers["accept"] == "application/json"
    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "signature-input")
  end

  test "public incoming output preserves optional amounts, timestamps and extensions with redaction" do
    response =
      Map.merge(@incoming_payment, %{
        "completed" => true,
        "incomingAmount" => %{
          "value" => "18446744073709551615",
          "assetCode" => "USD",
          "assetScale" => 2
        },
        "expiresAt" => "2026-12-01T09:20:50.520+02:00",
        "custom" => %{"nested" => [%{"sharedSecret" => "nested-secret", "enabled" => true}]}
      })

    base = HTTPServer.start({200, [], Jason.encode!(response)})

    for options <- [[], ["--json"]] do
      assert {stdout, "", 0} =
               invoke(["incoming", "get-public", base <> "/payment", "--allow-http"] ++ options)

      output = Jason.decode!(stdout)
      assert output["incomingAmount"] == response["incomingAmount"]
      assert output["createdAt"] == response["createdAt"]
      assert output["expiresAt"] == response["expiresAt"]
      assert output["completed"]

      assert output["custom"] == %{
               "nested" => [%{"sharedSecret" => "[REDACTED]", "enabled" => true}]
             }

      refute stdout =~ "test-secret"
      refute stdout =~ "nested-secret"
      assert String.contains?(String.trim_trailing(stdout), "\n") == (options == [])
      assert_received {:http_request, %{target: "/payment"}}
    end
  end

  test "public incoming reads require a resource URL and never fall back to WALLET_ADDRESS" do
    base = HTTPServer.start({200, [], Jason.encode!(@incoming_payment)})
    System.put_env("WALLET_ADDRESS", base <> "/wallet")

    for arguments <- [[], [""]] do
      assert_argument_error(
        ["incoming", "get-public"] ++ arguments,
        "Supply a full incoming-payment URL."
      )
    end

    for url <- [base <> "/payment", "$wallet.example/alice", "/payment", "not-a-url"] do
      assert_argument_error(
        ["incoming", "get-public", url],
        "Invalid incoming-payment URL. Use a full HTTPS resource URL; local HTTP requires --allow-http."
      )
    end

    for arguments <- [["extra"], ["--unknown"], ["--allow-http=invalid"]] do
      assert {"", _stderr, 2} = invoke(["incoming", "get-public", base] ++ arguments)
    end

    assert_argument_error(
      ["incoming", "get-public", base, "--version"],
      "The --version option cannot be combined with another command."
    )

    refute_received {:http_request, _}
  end

  test "public incoming help makes no request" do
    base = HTTPServer.start({200, [], Jason.encode!(@incoming_payment)})

    for arguments <- [[], [base, "--allow-http"]] do
      assert {stdout, "", 0} = invoke(["incoming", "get-public", "--help"] ++ arguments)
      assert stdout =~ "incoming get-public <url>"
    end

    refute_received {:http_request, _}
  end

  test "public incoming malformed and schema-invalid responses have safe errors" do
    for body <- [
          "not-json",
          "{}",
          Jason.encode!(Map.put(@incoming_payment, "receivedAmount", nil)),
          Jason.encode!(Map.put(@incoming_payment, "createdAt", "invalid-date")),
          Jason.encode!(
            Map.put(@incoming_payment, "methods", [%{"sharedSecret" => "sensitive-value"}])
          )
        ] do
      base = HTTPServer.start({200, [], body})

      for options <- [[], ["--json"]] do
        assert {"", stderr, 1} =
                 invoke(["incoming", "get-public", base <> "/payment", "--allow-http"] ++ options)

        assert stderr == "Error: Incoming-payment read returned an invalid response.\n"
        assert_received {:http_request, %{target: "/payment"}}
      end

      stop_supervised!(Task)
    end
  end

  test "public incoming HTTP failures and redirects omit server details and do not replay" do
    for status <- [302, 403, 404, 500] do
      body = Jason.encode!(%{"error" => %{"description" => "private-token"}})
      base = HTTPServer.start({status, [{"location", "/elsewhere"}], body})

      assert {"", stderr, 1} =
               invoke(["incoming", "get-public", base <> "/payment", "--allow-http", "--json"])

      assert stderr == "Error: Incoming-payment read failed (HTTP #{status}).\n"
      assert_received {:http_request, %{target: "/payment"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "public incoming transport failures return status 1 without retrying" do
    base = HTTPServer.start(:close)

    assert {"", stderr, 1} =
             invoke(["incoming", "get-public", base <> "/payment", "--allow-http"])

    assert stderr == "Error: Incoming-payment read failed due to a transport error.\n"
    assert_received {:http_request, %{target: "/payment"}}
    refute_receive {:http_request, _}, 20
  end

  test "public incoming reads support empty method arrays" do
    response = Map.put(@incoming_payment, "methods", [])
    base = HTTPServer.start({200, [], Jason.encode!(response)})

    assert {stdout, "", 0} =
             invoke(["incoming", "get-public", base <> "/payment", "--allow-http", "--json"])

    assert Jason.decode!(stdout) == response
    assert_received {:http_request, _}
  end

  test "keys validate imports an existing PEM file with explicit key ID" do
    path = write_key(@pem)
    previous = File.stat!(path)

    assert {stdout, "", 0} =
             invoke(["keys", "validate", "--key-file", path, "--key-id", "registered-key"])

    assert stdout == "Valid Ed25519 signing key\nKey ID  registered-key\n"
    assert File.read!(path) == @pem
    assert File.stat!(path).mtime == previous.mtime
    refute stdout =~ "PRIVATE KEY"
    refute stdout =~ "MC4CAQ"
  end

  test "keys validate uses environment file settings and emits a safe JSON summary" do
    System.put_env("KEY_ID", "environment-key")
    System.put_env("PRIVATE_KEY_FILE", write_key(@pem))
    System.put_env("WALLET_ADDRESS", "invalid-wallet-setting")

    assert {stdout, "", 0} = invoke(["keys", "validate", "--json"])
    assert Jason.decode!(stdout) == %{"valid" => true, "key_id" => "environment-key"}
    refute stdout =~ "MC4CAQ"
  end

  test "keys validate imports explicitly configured base64 PEM" do
    System.put_env("KEY_ID", "base64-key")
    encoded = Base.encode64(@pem)
    System.put_env("PRIVATE_KEY_BASE64", encoded)

    assert {stdout, "", 0} = invoke(["--json", "keys", "validate"])
    assert Jason.decode!(stdout) == %{"valid" => true, "key_id" => "base64-key"}
    refute stdout =~ encoded
  end

  test "key-file and key-id flags take precedence over environment settings" do
    path = write_key(@pem)
    System.put_env("KEY_ID", "environment-key")
    System.put_env("PRIVATE_KEY_FILE", "/invalid-key-path")
    System.put_env("PRIVATE_KEY_BASE64", "invalid-base64")

    assert {stdout, "", 0} =
             invoke([
               "keys",
               "validate",
               "--key-file",
               path,
               "--key-id",
               "explicit-key",
               "--json"
             ])

    assert Jason.decode!(stdout) == %{"valid" => true, "key_id" => "explicit-key"}
  end

  test "keys validate reports missing and conflicting configuration" do
    assert_argument_error(["keys", "validate"], "Supply --key-id or set KEY_ID.")
    System.put_env("KEY_ID", "registered-key")

    assert_argument_error(
      ["keys", "validate"],
      "Supply --key-file or set PRIVATE_KEY_FILE or PRIVATE_KEY_BASE64."
    )

    System.put_env("PRIVATE_KEY_FILE", "")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))
    assert {_stdout, "", 0} = invoke(["keys", "validate"])

    System.put_env("PRIVATE_KEY_FILE", write_key(@pem))

    assert_argument_error(
      ["keys", "validate"],
      "Set only one of PRIVATE_KEY_FILE and PRIVATE_KEY_BASE64."
    )
  end

  test "keys validate delegates malformed and public-only PEM rejection to the SDK" do
    public_pem = """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
    -----END PUBLIC KEY-----
    """

    System.put_env("KEY_ID", "registered-key")

    for contents <- ["private-value", public_pem] do
      path = write_key(contents)

      for options <- [[], ["--json"]] do
        assert_argument_error(
          ["keys", "validate", "--key-file", path] ++ options,
          "Invalid signing key. Check the key source, PEM format, and key ID."
        )
      end
    end
  end

  test "keys validate rejects missing files, invalid base64 and invalid key IDs safely" do
    System.put_env("KEY_ID", "registered-key")

    assert_argument_error(
      ["keys", "validate", "--key-file", "/private-value/missing.pem", "--json"],
      "Invalid signing key. Check the key source, PEM format, and key ID."
    )

    for encoded <- ["private-value!", Base.encode64("private-value")] do
      System.put_env("PRIVATE_KEY_BASE64", encoded)

      assert_argument_error(
        ["keys", "validate", "--json"],
        "Invalid signing key. Check the key source, PEM format, and key ID."
      )
    end

    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))

    for key_id <- ["", " "] do
      assert_argument_error(
        ["keys", "validate", "--key-id", key_id],
        "Invalid signing key. Check the key source, PEM format, and key ID."
      )
    end
  end

  test "keys validate requires explicit formats and ignores the ambiguous PRIVATE_KEY name" do
    System.put_env("KEY_ID", "registered-key")
    System.put_env("PRIVATE_KEY", Base.encode64(@pem))

    assert_argument_error(
      ["keys", "validate"],
      "Supply --key-file or set PRIVATE_KEY_FILE or PRIVATE_KEY_BASE64."
    )
  end

  test "keys validate help skips configuration and key flags are scoped to that command" do
    assert {stdout, "", 0} = invoke(["keys", "validate", "--help"])
    assert stdout =~ "keys validate"

    for arguments <- [
          ["keys", "validate", "extra"],
          ["keys", "validate", "--key-file"],
          ["keys", "validate", "--key-id"],
          ["keys", "validate", "--unknown"]
        ] do
      assert {"", _stderr, 2} = invoke(arguments)
    end

    assert_argument_error(
      ["keys", "validate", "--allow-http"],
      "The --allow-http option requires a resource command."
    )

    for arguments <- [
          ["version", "--key-file", "private-path"],
          ["wallet", "get", "--key-id", "id"]
        ] do
      assert_argument_error(
        arguments,
        "Signing-key options require keys validate or keys public."
      )
    end

    assert_argument_error(
      ["keys", "validate", "--version"],
      "The --version option cannot be combined with another command."
    )
  end

  test "keys public exports the RFC 8032 public JWK from an existing PEM file" do
    path = write_key(@pem)
    previous = File.stat!(path)
    expected = Map.put(@key, "kid", "registered-key")

    for options <- [[], ["--json"], ["--no-jwks", "--json"]] do
      assert {stdout, "", 0} =
               invoke(
                 ["keys", "public", "--key-file", path, "--key-id", "registered-key"] ++ options
               )

      assert Jason.decode!(stdout) == expected
      assert String.contains?(String.trim_trailing(stdout), "\n") == (options == [])
      refute stdout =~ "PRIVATE KEY"
      refute stdout =~ "MC4CAQ"
      refute stdout =~ path
    end

    assert File.read!(path) == @pem
    assert File.stat!(path).mtime == previous.mtime
  end

  test "keys public wraps the exported public key in a JWKS only when requested" do
    System.put_env("KEY_ID", "registered-key")
    System.put_env("PRIVATE_KEY_FILE", write_key(@pem))

    for options <- [["--jwks"], ["--jwks", "--json"], ["--jwks=true", "--json"]] do
      assert {stdout, "", 0} = invoke(["keys", "public"] ++ options)
      assert Jason.decode!(stdout) == %{"keys" => [Map.put(@key, "kid", "registered-key")]}
      assert String.contains?(String.trim_trailing(stdout), "\n") == (options == ["--jwks"])
      refute stdout =~ "MC4CAQ"
    end
  end

  test "keys public supports base64 PEM and shares explicit flag precedence" do
    System.put_env("KEY_ID", "base64-key")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))

    assert {stdout, "", 0} = invoke(["keys", "public", "--json"])
    assert Jason.decode!(stdout) == Map.put(@key, "kid", "base64-key")

    System.put_env("PRIVATE_KEY_FILE", "/invalid-path")
    System.put_env("PRIVATE_KEY_BASE64", "invalid-base64")

    assert {stdout, "", 0} =
             invoke([
               "keys",
               "public",
               "--key-file",
               write_key(@pem),
               "--key-id",
               "explicit-key",
               "--json"
             ])

    assert Jason.decode!(stdout) == Map.put(@key, "kid", "explicit-key")
  end

  test "keys public rejects missing, conflicting and invalid settings without exporting input" do
    assert_argument_error(["keys", "public"], "Supply --key-id or set KEY_ID.")
    System.put_env("KEY_ID", "registered-key")

    assert_argument_error(
      ["keys", "public"],
      "Supply --key-file or set PRIVATE_KEY_FILE or PRIVATE_KEY_BASE64."
    )

    System.put_env("PRIVATE_KEY_FILE", write_key(@pem))
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))

    assert_argument_error(
      ["keys", "public", "--jwks"],
      "Set only one of PRIVATE_KEY_FILE and PRIVATE_KEY_BASE64."
    )

    System.delete_env("PRIVATE_KEY_FILE")
    System.put_env("PRIVATE_KEY_BASE64", "private-value!")

    for options <- [[], ["--jwks", "--json"]] do
      assert_argument_error(
        ["keys", "public"] ++ options,
        "Invalid signing key. Check the key source, PEM format, and key ID."
      )
    end

    assert_argument_error(
      ["keys", "public", "--key-file", "/private-value/missing.pem", "--json"],
      "Invalid signing key. Check the key source, PEM format, and key ID."
    )
  end

  test "keys public help skips key import and JWKS selection is scoped to public export" do
    assert {stdout, "", 0} = invoke(["keys", "public", "--jwks", "--help"])
    assert stdout =~ "keys public"

    for arguments <- [
          ["keys", "public", "extra"],
          ["keys", "public", "--jwks=invalid"],
          ["keys", "public", "--key-id"],
          ["keys", "public", "--key-file"],
          ["keys", "public", "--unknown"]
        ] do
      assert {"", _stderr, 2} = invoke(arguments)
    end

    for arguments <- [["keys", "validate", "--jwks"], ["version", "--no-jwks"]] do
      assert_argument_error(arguments, "The --jwks option requires keys public.")
    end

    assert_argument_error(
      ["keys", "public", "--allow-http"],
      "The --allow-http option requires a resource command."
    )

    assert_argument_error(
      ["keys", "public", "--version"],
      "The --version option cannot be combined with another command."
    )
  end

  defp write_key(contents) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-snippets-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "key.pem")
    File.write!(path, contents)
    path
  end

  defp assert_argument_error(argv, message) do
    {stdout, stderr, status} = invoke(argv)
    assert status == 2
    assert stdout == ""
    assert stderr == "Error: #{message}\nRun open-payments help for usage.\n"
  end

  defp invoke(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:status, CLI.run(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:stdout, stdout}
    assert_received {:status, status}
    {stdout, stderr, status}
  end
end
