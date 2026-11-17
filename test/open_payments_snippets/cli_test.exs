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

  setup do
    previous = System.get_env("WALLET_ADDRESS")
    System.delete_env("WALLET_ADDRESS")

    on_exit(fn ->
      if previous,
        do: System.put_env("WALLET_ADDRESS", previous),
        else: System.delete_env("WALLET_ADDRESS")
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
        "The --json option requires version, wallet get, or wallet keys."
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
      assert_argument_error(argv, "The --allow-http option requires wallet get or wallet keys.")
    end

    assert_argument_error(
      ["wallet", "get", base, "--version"],
      "The --version option cannot be combined with wallet commands."
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
      "The --version option cannot be combined with wallet commands."
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
