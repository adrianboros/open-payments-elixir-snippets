defmodule OpenPaymentsSnippets.QuoteCreateTest do
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
  @receiver "https://receiver.example/tenant/incoming-payments/id?opaque=a%2Bb"
  @debit %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "000001", "assetCode" => "EUR", "assetScale" => 3}
  @quote %{
    "id" => "https://payments.example/tenant/quotes/id",
    "walletAddress" => "https://wallet.example/sender",
    "receiver" => @receiver,
    "debitAmount" => @debit,
    "receiveAmount" => @receive,
    "method" => "ilp",
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "expiresAt" => "opaque-expiry-string"
  }

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-quote-create-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-quote-create-token"
    })

    %{directory: directory, key: key}
  end

  test "file and UTF-8 stdin discover the sending wallet and submit exactly one signed POST", %{
    directory: directory
  } do
    base = server(@quote)
    payload = Map.put(payload(base), "debitAmount", Map.put(@debit, "memo", "Café 🌍"))
    source = Path.join(directory, "request.json")
    File.write!(source, Jason.encode!(payload))
    original = File.stat!(source)

    for {path, input} <- [{source, ""}, {"-", Jason.encode!(payload)}] do
      assert {stdout, "", 0} = invoke(arguments(path), input)
      assert Jason.decode!(stdout) == @quote
      refute stdout =~ "test-quote-create-token"

      assert_received {:http_request,
                       %{method: :GET, target: "/sending-wallet", headers: discovery}}

      refute Map.has_key?(discovery, "authorization")
      refute Map.has_key?(discovery, "signature")

      assert_received {:http_request,
                       %{method: :POST, target: "/tenant%2falpha/quotes", headers: headers} = post}

      assert Jason.decode!(post.body) == payload
      assert headers["authorization"] == "GNAP test-quote-create-token"
      assert headers["content-type"] == "application/json"
      assert headers["content-length"] == Integer.to_string(byte_size(post.body))
      assert valid_signature?(post)
      refute valid_signature?(%{post | body: post.body <> " "})
      refute valid_signature?(%{post | target: post.target <> "tampered"})

      refute valid_signature?(%{
               post
               | headers: Map.put(headers, "authorization", "GNAP changed-token")
             })

      refute_receive {:http_request, _}, 20
    end

    assert File.read!(source) == Jason.encode!(payload)
    assert File.stat!(source).mtime == original.mtime
  end

  test "fixed receive and receiver-inferred variants preserve payloads without amount defaults" do
    base = server(@quote, "/tenant%2falpha/")

    for input <- [Map.put(payload(base), "receiveAmount", @receive), payload(base)] do
      assert {stdout, "", 0} = invoke(arguments("-") ++ ["--json"], Jason.encode!(input))
      assert Jason.decode!(stdout) == @quote
      refute stdout =~ "\n "
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{target: "/tenant%2falpha/quotes", body: body}}
      assert Jason.decode!(body) == input
      refute_receive {:http_request, _}, 20
    end
  end

  test "returned amount extensions are redacted in text and compact JSON" do
    response =
      @quote
      |> put_in(["debitAmount", "sharedSecret"], "test-debit-secret")
      |> put_in(["receiveAmount", "nested"], [
        %{"sharedSecret" => "test-receive-secret", "keep" => true}
      ])

    base = server(response)

    for flags <- [[], ["--json"]] do
      assert {stdout, "", 0} = invoke(arguments("-") ++ flags, Jason.encode!(payload(base)))
      result = Jason.decode!(stdout)
      assert result["debitAmount"]["sharedSecret"] == "[REDACTED]"

      assert result["receiveAmount"]["nested"] == [
               %{"sharedSecret" => "[REDACTED]", "keep" => true}
             ]

      assert result["debitAmount"]["value"] == @debit["value"]
      assert result["receiveAmount"]["value"] == @receive["value"]
      assert result["expiresAt"] == "opaque-expiry-string"
      refute stdout =~ "test-"
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
    end
  end

  test "credential overrides do not replace the payload's sending wallet", %{
    directory: directory,
    key: key
  } do
    base = server(@quote)
    System.put_env("WALLET_ADDRESS", "invalid-signer")
    System.put_env("KEY_ID", "invalid-id")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-invalid-key")
    System.put_env("ACCESS_TOKEN", "invalid env token")
    token = Path.join(directory, "token.txt")
    File.write!(token, "file-quote-create-token\r\n")

    assert {stdout, "", 0} =
             invoke(
               arguments("-") ++
                 [
                   "--access-token-file",
                   token,
                   "--wallet-address",
                   "$client.example/other",
                   "--key-file",
                   key,
                   "--key-id",
                   "override-id"
                 ],
               Jason.encode!(payload(base))
             )

    refute stdout =~ "file-quote-create-token"
    assert_received {:http_request, %{target: "/sending-wallet"}}
    assert_received {:http_request, %{method: :POST, headers: headers, body: body}}
    assert headers["authorization"] == "GNAP file-quote-create-token"
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert Jason.decode!(body) == payload(base)
    assert File.read!(token) == "file-quote-create-token\r\n"
    assert File.read!(key) == @pem
  end

  test "missing, unreadable, malformed and invalid-encoding sources fail before discovery", %{
    directory: directory
  } do
    for {source, input} <- [
          {nil, ""},
          {"", ""},
          {"-", "private-invalid-json"},
          {"-", <<255>>},
          {directory, ""},
          {Path.join(directory, "private-missing.json"), ""}
        ] do
      args = ["quote", "create"] ++ if(source, do: [source], else: [])
      assert {"", stderr, 2} = invoke(args, input)
      refute stderr =~ "private-"
      refute stderr =~ directory
    end

    path = Path.join(directory, "invalid.json")
    File.write!(path, <<255>>)
    assert {"", stderr, 2} = invoke(arguments(path))
    assert stderr =~ "Quote request must contain valid JSON."
    refute_received {:http_request, _}
  end

  test "SDK rejects invalid amount combinations and payload shapes before discovery" do
    base = server(@quote)

    for input <- [
          nil,
          [],
          %{},
          Map.delete(payload(base), "method"),
          Map.put(payload(base), "walletAddress", "$wallet.example/sender"),
          Map.put(payload(base), "receiver", "$receiver.example/incoming"),
          Map.put(payload(base), "private-extra", "private-value"),
          Map.put(payload(base), "debitAmount", nil),
          payload(base) |> Map.put("debitAmount", @debit) |> Map.put("receiveAmount", @receive),
          Map.put(payload(base), "debitAmount", %{@debit | "value" => 1.5})
        ] do
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(input))
      assert stderr =~ "Invalid quote request"
      refute stderr =~ "private-"
    end

    refute_receive {:http_request, _}, 20
  end

  test "missing configuration fails before discovery and invalid tokens cannot produce a POST" do
    base = server(@quote)

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "Supply"
      System.put_env(name, previous)
    end

    refute_receive {:http_request, _}, 20
    System.put_env("ACCESS_TOKEN", "private invalid token")
    assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
    refute stderr =~ "private"
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "HTTP opt-in and SDK base-URL policy prevent unsafe requests" do
    base = server(@quote)
    assert {"", stderr, 2} = invoke(["quote", "create", "-"], Jason.encode!(payload(base)))
    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
    stop_supervised!(Task)

    for endpoint <- [
          "/tenant?private-query=1",
          "https://user:private-password@payments.example/tenant"
        ] do
      base = server(@quote, endpoint)
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "discovery failures stop before creation and omit response bodies" do
    for response <- [{401, [], "private-error"}, {200, [], "private-invalid-response"}] do
      base = HTTPServer.start(response)
      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "Wallet discovery"
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "creation HTTP failures do not retry or follow redirects" do
    for status <- [302, 401, 503] do
      base =
        server({status, [{"Location", "https://payments.example/redirect"}], "private-error"})

      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr == "Error: Quote creation failed (HTTP #{status}).\n"
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "ambiguous transport and invalid success responses never trigger another request" do
    for response <- [
          :close,
          {201, [], "private-invalid-json"},
          {200, [], Jason.encode!(@quote)},
          {201, [], Jason.encode!(Map.delete(@quote, "receiveAmount"))},
          {201, [], Jason.encode!(Map.put(@quote, "method", "private-method"))}
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "No automatic retry was made; the quote may have been created."
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "strict flag scope and help stay offline" do
    for args <- [
          ["quote", "create", "-", "extra"],
          ["quote", "create", "-", "--access-token", "private-token"],
          ["quote", "create", "-", "--output", "private-file"],
          ["quote", "create", "-", "--jwks"],
          ["quote", "create", "-", "--first", "1"],
          ["quote", "create", "-", "--cursor", "private-cursor"],
          ["quote", "create", "-", "--version"],
          ["quote", "create", "-", "--json=invalid"]
        ] do
      assert {"", stderr, 2} = invoke(args)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["quote", "create", "--help"])
    assert stdout =~ "quote create <file|->"
    refute_received {:http_request, _}
  end

  test "a created quote can be read explicitly without hidden receiver lookups" do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]
        quote = Map.put(@quote, "id", base <> "/tenant/quotes/id")

        case {wire.method, wire.target} do
          {:GET, "/sending-wallet"} -> {200, [], Jason.encode!(wallet(base, "/tenant"))}
          {:POST, "/tenant/quotes"} -> {201, [], Jason.encode!(quote)}
          {:GET, "/tenant/quotes/id"} -> {200, [], Jason.encode!(quote)}
        end
      end)

    assert {created, "", 0} = invoke(arguments("-") ++ ["--json"], Jason.encode!(payload(base)))
    id = Jason.decode!(created)["id"]
    assert {read, "", 0} = invoke(["quote", "get", id, "--allow-http", "--json"])
    assert Jason.decode!(read) == Jason.decode!(created)
    assert_received {:http_request, %{method: :GET, target: "/sending-wallet"}}
    assert_received {:http_request, %{method: :POST, target: "/tenant/quotes"}}
    assert_received {:http_request, %{method: :GET, target: "/tenant/quotes/id"}}
    refute_receive {:http_request, _}, 20
  end

  defp arguments(source), do: ["quote", "create", source, "--allow-http"]

  defp payload(base),
    do: %{
      "walletAddress" => base <> "/sending-wallet",
      "receiver" => @receiver,
      "method" => "ilp"
    }

  defp server(response, endpoint \\ "/tenant%2falpha") do
    HTTPServer.start(fn wire ->
      if wire.method == :GET do
        base = "http://" <> wire.headers["host"]
        {200, [], Jason.encode!(wallet(base, endpoint))}
      else
        if is_map(response), do: {201, [], Jason.encode!(response)}, else: response
      end
    end)
  end

  defp wallet(base, endpoint) do
    resource = if String.starts_with?(endpoint, "/"), do: base <> endpoint, else: endpoint

    %{
      "id" => base <> "/sending-wallet",
      "assetCode" => "USD",
      "assetScale" => 2,
      "authServer" => "https://auth.example/sender",
      "resourceServer" => resource
    }
  end

  defp valid_signature?(wire) do
    digest = "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"
    "sig1=" <> params = wire.headers["signature-input"]
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{wire.headers["host"]}#{wire.target}),
          ~s("authorization": #{wire.headers["authorization"]}),
          ~s("content-digest": #{wire.headers["content-digest"]}),
          ~s("content-length": #{wire.headers["content-length"]}),
          ~s("content-type": #{wire.headers["content-type"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    public = Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)

    digest == wire.headers["content-digest"] and
      :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [public, :ed25519])
  end

  defp invoke(argv, input \\ "") do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io([input: input], fn -> send(self(), {:status, CLI.run(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:stdout, stdout}
    assert_received {:status, status}
    {stdout, stderr, status}
  end
end
