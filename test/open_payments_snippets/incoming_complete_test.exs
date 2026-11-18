defmodule OpenPaymentsSnippets.IncomingCompleteTest do
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
  @amount %{"value" => "500", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://payments.example/tenant/incoming-payments/id",
    "walletAddress" => "https://wallet.example/receiver",
    "completed" => true,
    "receivedAmount" => %{"value" => "250", "assetCode" => "USD", "assetScale" => 2},
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "metadata" => %{"nested" => [%{"sharedSecret" => "test-metadata-secret", "keep" => true}]}
  }
  @method %{
    "type" => "ilp",
    "ilpAddress" => "g.example.receiver",
    "sharedSecret" => "test-ilp-secret"
  }

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-complete-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-complete-token"
    })

    %{directory: directory, key: key}
  end

  test "sends one signed POST without a body, preserving tenant paths and trailing slash" do
    base = server(@payment)

    for path <- ["/tenant%2falpha/incoming-payments/id", "/tenant%2falpha/incoming-payments/id/"] do
      assert {stdout, "", 0} = invoke(arguments(base <> path))
      assert Jason.decode!(stdout)["completed"] == true
      refute stdout =~ "test-complete-token"
      target = String.trim_trailing(path, "/") <> "/complete"

      assert_received {:http_request,
                       %{method: :POST, target: ^target, body: "", headers: headers} = post}

      assert headers["authorization"] == "GNAP test-complete-token"
      assert headers["signature-input"] =~ ~s(keyid="test-key")
      refute Map.has_key?(headers, "content-type")
      refute Map.has_key?(headers, "content-digest")
      assert valid_signature?(post)
      refute valid_signature?(%{post | target: target <> "tampered"})

      refute valid_signature?(%{
               post
               | headers: Map.put(headers, "authorization", "GNAP changed-token")
             })

      refute_receive {:http_request, _}, 20
    end
  end

  test "outputs detailed text and JSON, redacting nested shared secrets and preserving amount data" do
    base = server(@payment)

    for flags <- [[], ["--json"]] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/payment") ++ flags)
      result = Jason.decode!(stdout)

      assert result ==
               put_in(@payment, ["metadata", "nested"], [
                 %{"sharedSecret" => "[REDACTED]", "keep" => true}
               ])

      assert result["receivedAmount"]["value"] == "250"
      assert result["incomingAmount"]["value"] == "500"
      refute Map.has_key?(result, "methods")
      refute stdout =~ "test-metadata-secret"
      if flags == [], do: assert(stdout =~ "\n "), else: refute(stdout =~ "\n ")
      assert_received {:http_request, %{method: :POST}}
    end
  end

  test "supports existing token-file, signing and wallet flag precedence", %{
    directory: directory,
    key: key
  } do
    base = server(Map.delete(@payment, "incomingAmount"))
    System.put_env("ACCESS_TOKEN", "invalid env token")
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-id")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-invalid-key")
    token = Path.join(directory, "token.txt")
    File.write!(token, "file-complete-token\r\n")

    assert {stdout, "", 0} =
             invoke(
               arguments(base <> "/payment") ++
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

    refute Map.has_key?(Jason.decode!(stdout), "incomingAmount")
    refute stdout =~ "file-complete-token"
    assert_received {:http_request, %{headers: headers}}
    assert headers["authorization"] == "GNAP file-complete-token"
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert File.read!(token) == "file-complete-token\r\n"
    assert File.read!(key) == @pem
  end

  test "requires an explicit resource URL and rejects SDK query and HTTP-policy violations offline" do
    base = server(@payment)
    assert {"", stderr, 2} = invoke(["incoming", "complete"])
    assert stderr =~ "Supply a full incoming-payment URL."

    for url <- [
          "",
          "$payments.example/id",
          "/private-relative",
          "https://user:private-password@payments.example/id",
          "https://payments.example/id#private-fragment",
          base <> "/payment?",
          base <> "/payment?private-query=1"
        ] do
      assert {"", stderr, 2} = invoke(arguments(url))
      refute stderr =~ "private-"
      refute stderr =~ "test-complete-token"
    end

    assert {"", stderr, 2} = invoke(["incoming", "complete", base <> "/payment"])
    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
  end

  test "missing configuration and invalid token files do not produce requests", %{
    directory: directory
  } do
    base = server(@payment)

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments(base <> "/payment"))
      assert stderr =~ "Supply"
      System.put_env(name, previous)
    end

    token = Path.join(directory, "token.txt")
    File.write!(token, "private invalid token")

    for path <- [token, Path.join(directory, "private-missing-token")] do
      assert {"", stderr, 2} =
               invoke(arguments(base <> "/payment") ++ ["--access-token-file", path])

      refute stderr =~ "private"
      refute stderr =~ path
    end

    refute_receive {:http_request, _}, 20
  end

  test "HTTP errors do not retry, follow redirects, or expose server error bodies" do
    for status <- [302, 401, 409, 503] do
      base =
        HTTPServer.start(
          {status, [{"Location", "https://payments.example/redirect"}], "private-error-body"}
        )

      assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))
      assert stderr == "Error: Incoming-payment completion failed (HTTP #{status}).\n"
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "invalid success data leaves completion and asset checks with the SDK" do
    for response <- [
          {200, [], "private-invalid-json"},
          {201, [], Jason.encode!(@payment)},
          {200, [], Jason.encode!(Map.put(@payment, "completed", false))},
          {200, [], Jason.encode!(Map.put(@payment, "methods", [@method]))},
          {200, [], Jason.encode!(put_in(@payment, ["incomingAmount", "assetCode"], "EUR"))},
          {200, [], Jason.encode!(put_in(@payment, ["receivedAmount", "value"], 1.5))}
        ] do
      base = HTTPServer.start(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))

      assert stderr ==
               "Error: Incoming-payment completion returned an invalid response. No automatic retry was made; the payment may have been completed.\n"

      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "ambiguous transport failure does not retry or perform a follow-up read" do
    base = HTTPServer.start(:close)
    assert {"", stderr, 1} = invoke(arguments(base <> "/payment"))

    assert stderr ==
             "Error: Incoming-payment completion failed due to a transport error. No automatic retry was made; the payment may have been completed.\n"

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "strict flags and help stay offline" do
    for args <- [
          ["incoming", "complete", "https://payments.example/id", "extra"],
          [
            "incoming",
            "complete",
            "https://payments.example/id",
            "--access-token",
            "private-token"
          ],
          ["incoming", "complete", "https://payments.example/id", "--output", "private-file"],
          ["incoming", "complete", "https://payments.example/id", "--jwks"],
          ["incoming", "complete", "https://payments.example/id", "--version"],
          ["incoming", "complete", "https://payments.example/id", "--json=invalid"],
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

    assert {stdout, "", 0} = invoke(["incoming", "complete", "--help"])
    assert stdout =~ "incoming complete <url>"
    refute_received {:http_request, _}
  end

  test "CLI create then complete then read observes server state without hidden requests" do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]
        id = base <> "/tenant/incoming-payments/id"
        response = Map.merge(@payment, %{"id" => id, "walletAddress" => base <> "/receiver"})

        case {wire.method, wire.target} do
          {:GET, "/receiver"} ->
            {200, [],
             Jason.encode!(%{
               "id" => base <> "/receiver",
               "assetCode" => "USD",
               "assetScale" => 2,
               "authServer" => "https://auth.example/tenant",
               "resourceServer" => base <> "/tenant"
             })}

          {:POST, "/tenant/incoming-payments"} ->
            Process.put(:completed, false)

            created =
              response
              |> Map.put("completed", false)
              |> put_in(["receivedAmount", "value"], "0")
              |> Map.put("methods", [@method])

            {201, [], Jason.encode!(created)}

          {:POST, "/tenant/incoming-payments/id/complete"} ->
            Process.put(:completed, true)
            {200, [], Jason.encode!(response)}

          {:GET, "/tenant/incoming-payments/id"} ->
            {200, [],
             Jason.encode!(
               response
               |> Map.put("completed", Process.get(:completed))
               |> Map.put("methods", [@method])
             )}
        end
      end)

    payload = %{"walletAddress" => base <> "/receiver", "incomingAmount" => @amount}

    assert {created, "", 0} =
             invoke(["incoming", "create", "-", "--allow-http", "--json"], Jason.encode!(payload))

    id = Jason.decode!(created)["id"]
    assert Jason.decode!(created)["completed"] == false
    assert {completed, "", 0} = invoke(arguments(id) ++ ["--json"])
    assert Jason.decode!(completed)["completed"] == true
    assert {read, "", 0} = invoke(["incoming", "get", id, "--allow-http", "--json"])
    assert Jason.decode!(read)["completed"] == true
    refute created <> completed <> read =~ "test-"
    assert_received {:http_request, %{method: :GET, target: "/receiver"}}
    assert_received {:http_request, %{method: :POST, target: "/tenant/incoming-payments"}}

    assert_received {:http_request,
                     %{method: :POST, target: "/tenant/incoming-payments/id/complete"}}

    assert_received {:http_request, %{method: :GET, target: "/tenant/incoming-payments/id"}}
    refute_receive {:http_request, _}, 20
  end

  defp arguments(url), do: ["incoming", "complete", url, "--allow-http"]
  defp server(payment), do: HTTPServer.start({200, [], Jason.encode!(payment)})

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
