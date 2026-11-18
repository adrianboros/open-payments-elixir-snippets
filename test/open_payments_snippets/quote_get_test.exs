defmodule OpenPaymentsSnippets.QuoteGetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.HTTPServer

  # Public RFC 8032 test vector 1.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @quote %{
    "id" => "https://payments.example/tenant/quotes/id",
    "walletAddress" => "https://wallet.example/sender",
    "receiver" => "https://payments.example/tenant/incoming-payments/receiver",
    "debitAmount" => %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2},
    "receiveAmount" => %{"value" => "000001", "assetCode" => "EUR", "assetScale" => 3},
    "method" => "ilp",
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "expiresAt" => "opaque-expiry-string"
  }

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-quote-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "WALLET_ADDRESS" => "$client.example/signer",
      "KEY_ID" => "test-key",
      "PRIVATE_KEY_FILE" => key,
      "ACCESS_TOKEN" => "test-quote-token"
    })

    %{directory: directory, key: key}
  end

  test "sends one signed GET to the exact quote URL without discovery or body" do
    base = server(@quote)
    target = "/tenant/opaque%2fresource/../quote?part=a%2Bb&part=second"
    assert {stdout, "", 0} = invoke(arguments(base <> target))
    assert Jason.decode!(stdout) == @quote
    refute stdout =~ "test-quote-token"

    assert_received {:http_request,
                     %{method: :GET, target: ^target, body: "", headers: headers} = wire}

    assert headers["authorization"] == "GNAP test-quote-token"
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    refute Map.has_key?(headers, "content-type")
    refute Map.has_key?(headers, "content-digest")
    assert valid_signature?(wire)
    refute valid_signature?(%{wire | target: target <> "tampered"})

    refute valid_signature?(%{
             wire
             | headers: Map.put(headers, "authorization", "GNAP changed-token")
           })

    refute_receive {:http_request, _}, 20
  end

  test "SDK JSON preserves cross-asset amounts and expiry spelling while redacting nested shared secrets" do
    response =
      @quote
      |> put_in(["debitAmount", "sharedSecret"], "test-debit-secret")
      |> put_in(["receiveAmount", "nested"], [
        %{"sharedSecret" => "test-receive-secret", "keep" => true}
      ])

    base = server(response)

    for flags <- [[], ["--json"], ["--json=false"]] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/quote") ++ flags)
      result = Jason.decode!(stdout)
      assert result["debitAmount"]["value"] == "18446744073709551615"
      assert result["receiveAmount"]["value"] == "000001"
      assert result["debitAmount"]["assetCode"] == "USD"
      assert result["receiveAmount"]["assetCode"] == "EUR"
      assert result["receiveAmount"]["assetScale"] == 3
      assert result["debitAmount"]["sharedSecret"] == "[REDACTED]"

      assert result["receiveAmount"]["nested"] == [
               %{"sharedSecret" => "[REDACTED]", "keep" => true}
             ]

      assert result["createdAt"] == @quote["createdAt"]
      assert result["expiresAt"] == "opaque-expiry-string"
      refute stdout =~ "test-"
      if flags == ["--json"], do: refute(stdout =~ "\n "), else: assert(stdout =~ "\n ")
      assert_received {:http_request, %{method: :GET}}
    end
  end

  test "omitted expiry stays omitted and SDK quote fields are not inferred from the requested URL" do
    response = Map.delete(@quote, "expiresAt")
    base = server(response)
    assert {stdout, "", 0} = invoke(arguments(base <> "/unrelated-opaque-id") ++ ["--json"])
    assert Jason.decode!(stdout) == response
    assert_received {:http_request, %{target: "/unrelated-opaque-id"}}
    refute_receive {:http_request, _}, 20
  end

  test "shared token-file and signing configuration preserve precedence and source files", %{
    directory: directory,
    key: key
  } do
    base = server(@quote)
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-id")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "invalid-conflicting-key")
    System.put_env("ACCESS_TOKEN", "invalid env token")

    for {ending, index} <- Enum.with_index(["", "\n", "\r\n"]) do
      token = Path.join(directory, "token-#{index}.txt")
      File.write!(token, "file-quote-token" <> ending)
      original = File.stat!(token)

      assert {stdout, "", 0} =
               invoke(
                 arguments(base <> "/quote") ++
                   [
                     "--access-token-file",
                     token,
                     "--wallet-address",
                     "$client.example/other",
                     "--key-file",
                     key,
                     "--key-id",
                     "override-id"
                   ]
               )

      refute stdout =~ "file-quote-token"
      assert_received {:http_request, %{headers: headers}}
      assert headers["authorization"] == "GNAP file-quote-token"
      assert headers["signature-input"] =~ ~s(keyid="override-id")
      assert File.read!(token) == "file-quote-token" <> ending
      assert File.stat!(token).mtime == original.mtime
    end

    assert File.read!(key) == @pem
  end

  test "accepts exported base64 PEM settings" do
    base = server(@quote)
    System.delete_env("PRIVATE_KEY_FILE")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))
    assert {_, "", 0} = invoke(arguments(base <> "/quote"))
    assert_received {:http_request, %{method: :GET}}
  end

  test "requires an explicit URL and signing/token configuration before HTTP", %{
    directory: directory
  } do
    base = server(@quote)
    assert {"", stderr, 2} = invoke(["quote", "get"])
    assert stderr =~ "Supply a full quote URL."

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments(base <> "/quote"))
      assert stderr =~ "Supply"
      System.put_env(name, previous)
    end

    token = Path.join(directory, "token.txt")
    File.write!(token, "private invalid token")

    for path <- [token, Path.join(directory, "private-missing-token")] do
      assert {"", stderr, 2} =
               invoke(arguments(base <> "/quote") ++ ["--access-token-file", path])

      refute stderr =~ "private"
      refute stderr =~ path
    end

    System.put_env("ACCESS_TOKEN", "invalid private token")
    assert {"", stderr, 2} = invoke(arguments(base <> "/quote"))
    refute stderr =~ "private"
    refute_receive {:http_request, _}, 20
  end

  test "keeps resource URL and HTTP policy validation in the SDK" do
    base = server(@quote)

    for url <- [
          "",
          "$payments.example/quote",
          "private-relative-url",
          "https://user:private-password@payments.example/id",
          "https://payments.example/id#private-fragment"
        ] do
      assert {"", stderr, 2} = invoke(arguments(url))
      refute stderr =~ "private-"
    end

    assert {"", stderr, 2} = invoke(["quote", "get", base <> "/quote"])
    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
  end

  test "HTTP failures do not retry, redirect, or expose server error bodies" do
    for status <- [302, 401, 403, 503] do
      base =
        HTTPServer.start(
          {status, [{"Location", "https://payments.example/redirect"}], "private-error-body"}
        )

      assert {"", stderr, 1} = invoke(arguments(base <> "/quote"))
      assert stderr == "Error: Quote read failed (HTTP #{status}).\n"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "invalid success data remains an SDK response error with no partial output" do
    for response <- [
          {200, [], "private-invalid-json"},
          {201, [], Jason.encode!(@quote)},
          {200, [], Jason.encode!(Map.delete(@quote, "receiveAmount"))},
          {200, [], Jason.encode!(Map.put(@quote, "sentAmount", @quote["debitAmount"]))},
          {200, [], Jason.encode!(Map.put(@quote, "method", "private-method"))},
          {200, [], Jason.encode!(put_in(@quote, ["debitAmount", "value"], 1.5))},
          {200, [], Jason.encode!(Map.put(@quote, "expiresAt", nil))}
        ] do
      base = HTTPServer.start(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/quote"))
      assert stderr == "Error: Quote read returned an invalid response.\n"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "transport failure has no retry or related-resource request" do
    base = HTTPServer.start(:close)
    assert {"", stderr, 1} = invoke(arguments(base <> "/quote"))
    assert stderr == "Error: Quote read failed due to a transport error.\n"
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "strict options and help keep quote reads separate from pagination and grant output" do
    for args <- [
          ["quote", "get", "https://payments.example/id", "extra"],
          ["quote", "get", "https://payments.example/id", "--access-token", "private-token"],
          ["quote", "get", "https://payments.example/id", "--output", "private-file"],
          ["quote", "get", "https://payments.example/id", "--jwks"],
          ["quote", "get", "https://payments.example/id", "--version"],
          ["quote", "get", "https://payments.example/id", "--first", "1"],
          ["quote", "get", "https://payments.example/id", "--last", "1"],
          ["quote", "get", "https://payments.example/id", "--cursor", "private-cursor"],
          ["quote", "get", "https://payments.example/id", "--json=invalid"],
          ["grant", "request", "-", "--access-token-file", "private-file"]
        ] do
      assert {"", stderr, 2} = invoke(args)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["quote", "get", "--help"])
    assert stdout =~ "quote get <url>"
    refute_received {:http_request, _}
  end

  defp arguments(url), do: ["quote", "get", url, "--allow-http"]
  defp server(quote), do: HTTPServer.start({200, [], Jason.encode!(quote)})

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
