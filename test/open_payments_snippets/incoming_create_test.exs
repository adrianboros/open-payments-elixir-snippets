defmodule OpenPaymentsSnippets.IncomingCreateTest do
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
  @amount %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://payments.example/tenant/incoming-payments/id",
    "walletAddress" => "https://wallet.example/receiver",
    "completed" => false,
    "receivedAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "methods" => [
      %{
        "type" => "ilp",
        "ilpAddress" => "g.example.receiver",
        "sharedSecret" => "test-ilp-secret"
      }
    ],
    "metadata" => %{"nested" => [%{"sharedSecret" => "test-metadata-secret", "keep" => true}]}
  }

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-create-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-create-token"
    })

    %{directory: directory, key: key}
  end

  test "file and stdin discover the receiving wallet then send one signed POST", %{
    directory: directory
  } do
    base = server(@payment)

    payload =
      Map.merge(payload(base), %{
        "incomingAmount" => @amount,
        "expiresAt" => "2026-11-19T01:02:03+02:00",
        "metadata" => %{"memo" => "Café 🌍", "items" => [1, true, nil]}
      })

    path = Path.join(directory, "request.json")
    File.write!(path, Jason.encode!(payload))
    original = File.stat!(path)

    for {source, input} <- [{path, ""}, {"-", Jason.encode!(payload)}] do
      assert {stdout, "", 0} = invoke(arguments(source), input)
      result = Jason.decode!(stdout)
      assert result["id"] == @payment["id"]
      assert result["incomingAmount"] == @amount
      assert result["methods"] |> hd() |> Map.fetch!("sharedSecret") == "[REDACTED]"
      assert result["metadata"]["nested"] == [%{"sharedSecret" => "[REDACTED]", "keep" => true}]
      refute stdout =~ "test-"

      assert_received {:http_request,
                       %{method: :GET, target: "/receiving-wallet", headers: headers}}

      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(headers, "signature")

      assert_received {:http_request,
                       %{method: :POST, target: "/tenant%2falpha/incoming-payments"} = post}

      assert Jason.decode!(post.body) == payload
      assert post.headers["authorization"] == "GNAP test-create-token"
      assert post.headers["content-type"] == "application/json"
      assert post.headers["content-length"] == Integer.to_string(byte_size(post.body))
      assert valid_signature?(post)
      refute valid_signature?(%{post | body: post.body <> " "})
      refute valid_signature?(%{post | target: post.target <> "tampered"})

      refute valid_signature?(%{
               post
               | headers: Map.put(post.headers, "authorization", "GNAP changed-token")
             })

      refute_receive {:http_request, _}, 20
    end

    assert File.read!(path) == Jason.encode!(payload)
    assert File.stat!(path).mtime == original.mtime
  end

  test "minimal payload, trailing resource-server slash, and compact JSON work" do
    base = server(Map.delete(@payment, "incomingAmount"), "/tenant%2falpha/")
    assert {stdout, "", 0} = invoke(arguments("-") ++ ["--json"], Jason.encode!(payload(base)))
    result = Jason.decode!(stdout)
    refute Map.has_key?(result, "incomingAmount")
    refute stdout =~ "\n "
    assert result["receivedAmount"]["value"] == "0"
    assert result["completed"] == false
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{target: "/tenant%2falpha/incoming-payments", body: body}}
    assert Jason.decode!(body) == payload(base)
  end

  test "credential flags override defaults without changing the receiving payload", %{
    directory: directory,
    key: key
  } do
    base = server(@payment)
    System.put_env("WALLET_ADDRESS", "invalid-signer")
    System.put_env("KEY_ID", "invalid-key")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-invalid-key")
    System.put_env("ACCESS_TOKEN", "invalid env token")
    token = Path.join(directory, "token.txt")
    File.write!(token, "file-create-token\r\n")

    args =
      arguments("-") ++
        [
          "--access-token-file",
          token,
          "--key-file",
          key,
          "--key-id",
          "override-id",
          "--wallet-address",
          "$client.example/other"
        ]

    assert {stdout, "", 0} = invoke(args, Jason.encode!(payload(base)))
    refute stdout =~ "file-create-token"
    assert_received {:http_request, %{method: :GET, target: "/receiving-wallet"}}
    assert_received {:http_request, %{method: :POST, headers: headers, body: body}}
    assert headers["authorization"] == "GNAP file-create-token"
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert Jason.decode!(body) == payload(base)
    assert File.read!(token) == "file-create-token\r\n"
    assert File.read!(key) == @pem
  end

  test "missing, unreadable, malformed, and invalid-encoding input fail before discovery", %{
    directory: directory
  } do
    for {source, input} <- [
          {nil, ""},
          {"", ""},
          {"-", "test-private-invalid-json"},
          {"-", <<255>>},
          {directory, ""},
          {Path.join(directory, "private-missing.json"), ""}
        ] do
      args = ["incoming", "create"] ++ if(source, do: [source], else: [])
      assert {"", stderr, 2} = invoke(args, input)
      refute stderr =~ "test-private"
      refute stderr =~ directory
    end

    path = Path.join(directory, "invalid.json")
    File.write!(path, <<255>>)
    assert {"", stderr, 2} = invoke(arguments(path))
    assert stderr =~ "Incoming-payment request must contain valid JSON."
    refute_received {:http_request, _}
  end

  test "SDK rejects incomplete, extra, null, and malformed payload fields before discovery" do
    base = server(@payment)

    for data <- [
          nil,
          [],
          %{},
          %{"walletAddress" => "$wallet.example/receiver"},
          Map.put(payload(base), "metadata", nil),
          Map.put(payload(base), "private-extra", "private-value"),
          Map.put(payload(base), "incomingAmount", %{@amount | "value" => 1.5})
        ] do
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(data))
      assert stderr =~ "Invalid incoming-payment request"
      refute stderr =~ "private-"
    end

    refute_receive {:http_request, _}, 20
  end

  test "missing signing, wallet, or token configuration fails before discovery" do
    base = server(@payment)

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "Supply"
      System.put_env(name, previous)
    end

    refute_receive {:http_request, _}, 20
  end

  test "invalid tokens and discovered resource URLs cannot produce a signed POST" do
    for endpoint <- [
          "/tenant?private-query=1",
          "https://user:private-password@payments.example/tenant"
        ] do
      base = server(@payment, endpoint)
      assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end

    base = server(@payment)
    System.put_env("ACCESS_TOKEN", "invalid private token")
    assert {"", stderr, 2} = invoke(arguments("-"), Jason.encode!(payload(base)))
    refute stderr =~ "private"
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "HTTP discovery requires explicit opt-in" do
    base = server(@payment)
    assert {"", stderr, 2} = invoke(["incoming", "create", "-"], Jason.encode!(payload(base)))
    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
  end

  test "discovery failures stop before creation and omit server error bodies" do
    for {status, body} <- [{401, "private-server-error"}, {200, "private-invalid-response"}] do
      base = HTTPServer.start({status, [], body})
      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "Wallet discovery"
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "creation HTTP errors do not redirect, retry, or expose response bodies" do
    for status <- [302, 401, 503] do
      base =
        server(
          {status, [{"Location", "https://payments.example/redirect"}], "private-error-body"}
        )

      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr == "Error: Incoming-payment creation failed (HTTP #{status}).\n"
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "ambiguous transport and invalid success responses do not retry" do
    for response <- [
          :close,
          {201, [], "private-invalid-json"},
          {200, [], Jason.encode!(@payment)},
          {201, [], Jason.encode!(Map.put(@payment, "completed", true))},
          {201, [], Jason.encode!(put_in(@payment, ["receivedAmount", "value"], "1"))},
          {201, [], Jason.encode!(put_in(@payment, ["incomingAmount", "assetCode"], "EUR"))}
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments("-"), Jason.encode!(payload(base)))
      assert stderr =~ "No automatic retry was made; the payment may have been created."
      refute stderr =~ "private-"
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "arguments and flags stay strict and help makes no request" do
    for args <- [
          ["incoming", "create", "-", "extra"],
          ["incoming", "create", "-", "--access-token", "private-token"],
          ["incoming", "create", "-", "--output", "private-file"],
          ["incoming", "create", "-", "--jwks"],
          ["incoming", "create", "-", "--version"],
          ["incoming", "create", "-", "--json=invalid"],
          [
            "incoming",
            "get-public",
            "https://payments.example/id",
            "--access-token-file",
            "private-file"
          ]
        ] do
      assert {"", stderr, 2} = invoke(args)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["incoming", "create", "--help"])
    assert stdout =~ "incoming create <file|->"
    refute_received {:http_request, _}
  end

  defp arguments(source), do: ["incoming", "create", source, "--allow-http"]
  defp payload(base), do: %{"walletAddress" => base <> "/receiving-wallet"}

  defp server(response, endpoint \\ "/tenant%2falpha") do
    HTTPServer.start(fn wire ->
      if wire.method == :GET do
        base = "http://" <> wire.headers["host"]
        resource = if String.starts_with?(endpoint, "/"), do: base <> endpoint, else: endpoint

        wallet = %{
          "id" => base <> "/receiving-wallet",
          "assetCode" => "USD",
          "assetScale" => 2,
          "authServer" => "https://auth.example/receiver",
          "resourceServer" => resource
        }

        {200, [], Jason.encode!(wallet)}
      else
        if is_map(response), do: {201, [], Jason.encode!(response)}, else: response
      end
    end)
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
