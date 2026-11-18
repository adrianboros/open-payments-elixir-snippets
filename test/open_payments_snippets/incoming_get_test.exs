defmodule OpenPaymentsSnippets.IncomingGetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.HTTPServer

  # Public RFC 8032 test vector 1, not an operational signing key.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @token "test-resource-token"
  @amount %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://payments.example/tenant/incoming-payments/id",
    "walletAddress" => "https://wallet.example/alice",
    "completed" => false,
    "receivedAmount" => @amount,
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "expiresAt" => "2026-11-19T12:34:56.123456+02:00",
    "methods" => [
      %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-ilp-secret"}
    ],
    "metadata" => %{"description" => "Test payment"}
  }

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-incoming-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    names = ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 PRIVATE_KEY ACCESS_TOKEN)
    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    key = Path.join(directory, "rfc8032.pem")
    File.write!(key, @pem)

    System.put_env(%{
      "WALLET_ADDRESS" => "$wallet.example/alice",
      "KEY_ID" => "test-key",
      "PRIVATE_KEY_FILE" => key,
      "ACCESS_TOKEN" => @token
    })

    %{directory: directory, key: key}
  end

  test "sends one signed GNAP GET to the exact resource URL without discovery or a body" do
    base = server(@payment)
    target = "/tenant/opaque%2fresource/../payment?part=a%2Bb&part=second"
    assert {stdout, "", 0} = invoke(arguments(base <> target))
    assert Jason.decode!(stdout)["walletAddress"] == @payment["walletAddress"]
    refute stdout =~ @token
    refute stdout =~ "test-ilp-secret"

    assert_received {:http_request,
                     %{method: :GET, target: ^target, headers: headers, body: ""} = wire}

    assert headers["authorization"] == "GNAP " <> @token
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    refute Map.has_key?(headers, "content-type")
    refute Map.has_key?(headers, "content-digest")
    assert valid_signature?(wire)
    refute valid_signature?(%{wire | target: wire.target <> "tampered"})

    refute valid_signature?(%{
             wire
             | headers: Map.put(headers, "authorization", "GNAP changed-token")
           })

    refute_receive {:http_request, _}, 20
  end

  test "formats text and JSON while redacting sharedSecret recursively and preserving SDK data" do
    response =
      @payment
      |> put_in(["receivedAmount", "sharedSecret"], "test-amount-secret")
      |> put_in(["metadata", "nested"], [
        %{"sharedSecret" => "test-metadata-secret", "keep" => true}
      ])
      |> Map.put("extension", %{"sharedSecret" => "test-extension-secret", "value" => [1, nil]})

    base = server(response)

    for options <- [[], ["--json"], ["--json=false"]] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/payment") ++ options)
      result = Jason.decode!(stdout)
      assert result["methods"] |> hd() |> Map.fetch!("sharedSecret") == "[REDACTED]"
      assert result["receivedAmount"]["sharedSecret"] == "[REDACTED]"
      assert result["metadata"]["nested"] == [%{"sharedSecret" => "[REDACTED]", "keep" => true}]
      assert result["extension"] == %{"sharedSecret" => "[REDACTED]", "value" => [1, nil]}
      assert result["incomingAmount"] == @amount
      assert result["receivedAmount"]["value"] == @amount["value"]
      assert result["createdAt"] == @payment["createdAt"]
      assert result["expiresAt"] == @payment["expiresAt"]
      assert result["metadata"]["description"] == "Test payment"
      refute stdout =~ "test-"
      if options == ["--json"], do: refute(stdout =~ "\n "), else: assert(stdout =~ "\n ")
      assert_received {:http_request, %{method: :GET}}
    end

    refute_receive {:http_request, _}, 20
  end

  test "token files override the environment, accept one LF or CRLF, and remain unchanged", %{
    directory: directory
  } do
    base = server(@payment)
    System.put_env("ACCESS_TOKEN", "invalid env token")

    for {ending, index} <- Enum.with_index(["", "\n", "\r\n"]) do
      path = Path.join(directory, "token-#{index}")
      File.write!(path, "file-token" <> ending)
      original = File.stat!(path)

      assert {stdout, "", 0} =
               invoke(arguments(base <> "/payment") ++ ["--access-token-file", path])

      refute stdout =~ "file-token"
      assert_received {:http_request, %{headers: %{"authorization" => "GNAP file-token"}}}
      assert File.read!(path) == "file-token" <> ending
      assert File.stat!(path).mtime == original.mtime
    end
  end

  test "key and wallet flags override environment defaults without wallet discovery", %{key: key} do
    base = server(@payment)
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-id")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "invalid-conflicting-key")

    assert {_, "", 0} =
             invoke(
               arguments(base <> "/payment") ++
                 [
                   "--key-file",
                   key,
                   "--key-id",
                   "override-id",
                   "--wallet-address",
                   "$wallet.example/other"
                 ]
             )

    assert_received {:http_request, %{target: "/payment", headers: headers}}
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    refute_receive {:http_request, _}, 20
  end

  test "supports the existing base64 PEM configuration" do
    base = server(@payment)
    System.delete_env("PRIVATE_KEY_FILE")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))
    assert {_, "", 0} = invoke(arguments(base <> "/payment"))
    assert_received {:http_request, %{headers: %{"authorization" => "GNAP " <> @token}}}
  end

  test "requires explicit URL, wallet, key, and resource-token configuration before HTTP" do
    base = server(@payment)
    assert {"", stderr, 2} = invoke(["incoming", "get"])
    assert stderr =~ "Supply a full incoming-payment URL."

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments(base <> "/payment"))
      assert stderr =~ "Supply"
      refute stderr =~ @token
      System.put_env(name, previous)
    end

    refute_receive {:http_request, _}, 20
  end

  test "rejects invalid tokens and unreadable files with safe errors and no HTTP", %{
    directory: directory
  } do
    base = server(@payment)

    for {value, index} <-
          Enum.with_index([
            "",
            "private token",
            "private\r\nheader",
            "private\n\n",
            "private\r",
            <<255>>
          ]) do
      path = Path.join(directory, "invalid-token-#{index}")
      File.write!(path, value)

      assert {"", stderr, 2} =
               invoke(arguments(base <> "/payment") ++ ["--access-token-file", path])

      refute stderr =~ "private"
      refute stderr =~ path
    end

    for path <- [Path.join(directory, "missing-private-token"), directory] do
      assert {"", stderr, 2} =
               invoke(arguments(base <> "/payment") ++ ["--access-token-file", path])

      assert stderr =~ "Unable to read access-token file."
      refute stderr =~ path
    end

    for value <- ["", "invalid private token", "private\nheader"] do
      System.put_env("ACCESS_TOKEN", value)
      assert {"", stderr, 2} = invoke(arguments(base <> "/payment"))
      refute stderr =~ "private"
    end

    refute_receive {:http_request, _}, 20
  end

  test "enforces SDK resource URL policy without echoing rejected URLs" do
    base = server(@payment)

    for url <- [
          "",
          base <> "/payment",
          "$payments.example/payment",
          "relative-private-url",
          "https://user:private-password@payments.example/id",
          "https://payments.example/id#private-fragment"
        ] do
      assert {"", stderr, 2} = invoke(["incoming", "get", url])
      refute stderr =~ "private-"
      refute stderr =~ @token
    end

    refute_receive {:http_request, _}, 20
  end

  test "reports HTTP failures without leaking bodies or following redirects or retrying" do
    for status <- [302, 401, 403, 503] do
      base =
        HTTPServer.start(
          {status, [{"Location", "https://payments.example/redirect"}],
           ~s({"error":"test-private-error-body"})}
        )

      assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))
      assert stderr == "Error: Authenticated incoming-payment read failed (HTTP #{status}).\n"
      refute stderr =~ @token
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "leaves response schema and asset consistency checks to the SDK" do
    for {status, body} <- [
          {200, "test-private-invalid-json"},
          {201, Jason.encode!(@payment)},
          {200, Jason.encode!(Map.delete(@payment, "walletAddress"))},
          {200, Jason.encode!(Map.delete(@payment, "methods"))},
          {200, Jason.encode!(put_in(@payment, ["incomingAmount", "assetCode"], "EUR"))},
          {200, Jason.encode!(put_in(@payment, ["receivedAmount", "value"], 1.5))}
        ] do
      base = HTTPServer.start({status, [], body})
      assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))

      assert stderr ==
               "Error: Authenticated incoming-payment read returned an invalid response.\n"

      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "reports transport failure without retrying or exposing credentials" do
    base = HTTPServer.start(:close)
    assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))

    assert stderr ==
             "Error: Authenticated incoming-payment read failed due to a transport error.\n"

    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "public reads stay unsigned with signing settings and access token configured" do
    response = Map.put(@payment, "authServer", "https://auth.example/tenant")
    base = server(response)

    assert {stdout, "", 0} =
             invoke(["incoming", "get-public", base <> "/payment", "--allow-http"])

    refute stdout =~ "test-ilp-secret"
    refute stdout =~ @token
    assert_received {:http_request, %{headers: headers}}
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "authorization")
  end

  test "scopes credential flags and rejects secret-bearing command-line arguments" do
    for argv <- [
          ["incoming", "get", "https://payments.example/id", "extra"],
          ["incoming", "get", "https://payments.example/id", "--access-token", "private-token"],
          ["incoming", "get", "https://payments.example/id", "--output", "private-file"],
          ["incoming", "get", "https://payments.example/id", "--jwks"],
          ["incoming", "get", "https://payments.example/id", "--version"],
          [
            "incoming",
            "get-public",
            "https://payments.example/id",
            "--access-token-file",
            "private-file"
          ],
          ["grant", "request", "-", "--access-token-file", "private-file"],
          ["keys", "validate", "--access-token-file", "private-file"],
          ["wallet", "get", "--wallet-address", "https://wallet.example/alice"]
        ] do
      assert {"", stderr, 2} = invoke(argv)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["incoming", "get", "--help"])
    assert stdout =~ "incoming get <url>"
    assert stdout =~ "--access-token-file"
    refute_received {:http_request, _}
  end

  defp arguments(url), do: ["incoming", "get", url, "--allow-http"]
  defp server(payment), do: HTTPServer.start({200, [], Jason.encode!(payment)})

  # Reconstruct the signature from the actual wire using the public RFC key.
  defp valid_signature?(wire) do
    "sig1=" <> params = wire.headers["signature-input"]
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{wire.headers["host"]}#{wire.target}),
          ~s("authorization": #{wire.headers["authorization"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    public = Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)
    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [public, :ed25519])
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
