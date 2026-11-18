defmodule OpenPaymentsSnippets.IncomingListTest do
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
  @wallet "https://wallet.example/receiver"
  @amount %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://payments.example/tenant/incoming-payments/id",
    "walletAddress" => @wallet,
    "completed" => false,
    "receivedAmount" => @amount,
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T12:34:56.123456+02:00",
    "metadata" => %{"nested" => [%{"sharedSecret" => "test-metadata-secret", "keep" => true}]}
  }
  @page %{
    "pagination" => %{
      "hasNextPage" => true,
      "hasPreviousPage" => false,
      "startCursor" => "opaque-start",
      "endCursor" => "opaque-end"
    },
    "result" => [@payment, Map.put(@payment, "completed", true), @payment],
    "extension" => %{"sharedSecret" => "test-page-secret", "keep" => true}
  }
  @target "/tenant%2falpha/incoming-payments?wallet-address=https%3A%2F%2Fwallet.example%2Freceiver"

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-list-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-list-token"
    })

    %{directory: directory, key: key}
  end

  test "discovers the requested wallet and signs the exact encoded page URL once" do
    base = server(@page)
    cursor = "cursor +/%?&=é"

    assert {stdout, "", 0} =
             invoke(arguments(base <> "/receiver") ++ ["--first", "2", "--cursor", cursor])

    assert length(Jason.decode!(stdout)["result"]) == 3
    assert_received {:http_request, %{method: :GET, target: "/receiver", headers: discovery}}
    refute Map.has_key?(discovery, "authorization")
    refute Map.has_key?(discovery, "signature")
    target = @target <> "&cursor=cursor+%2B%2F%25%3F%26%3D%C3%A9&first=2"

    assert_received {:http_request,
                     %{method: :GET, target: ^target, body: "", headers: headers} = wire}

    assert headers["authorization"] == "GNAP test-list-token"
    assert headers["accept"] == "application/json"
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

  test "omits pagination defaults and preserves page flags, order, duplicates and redaction" do
    base = server(@page)

    for flags <- [[], ["--json"]] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/receiver") ++ flags)
      result = Jason.decode!(stdout)
      assert result["pagination"] == @page["pagination"]
      assert Enum.map(result["result"], & &1["completed"]) == [false, true, false]
      assert hd(result["result"]) == List.last(result["result"])
      assert hd(result["result"])["receivedAmount"] == @amount
      assert hd(result["result"])["createdAt"] == @payment["createdAt"]

      assert hd(result["result"])["metadata"]["nested"] == [
               %{"sharedSecret" => "[REDACTED]", "keep" => true}
             ]

      assert result["extension"] == %{"sharedSecret" => "[REDACTED]", "keep" => true}
      refute stdout =~ "test-"
      if flags == [], do: assert(stdout =~ "\n "), else: refute(stdout =~ "\n ")
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
    end
  end

  test "supports backward, cursor-only and boundary counts with an empty result page" do
    page = %{"pagination" => %{"hasNextPage" => false, "hasPreviousPage" => true}, "result" => []}
    base = server(page, "/tenant%2falpha/")

    for {flags, query} <- [
          {["--last", "100", "--cursor", "opaque"], "&cursor=opaque&last=100"},
          {["--cursor", "opaque"], "&cursor=opaque"},
          {["--first", "1"], "&first=1"}
        ] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/receiver") ++ flags ++ ["--json"])
      assert Jason.decode!(stdout) == page
      target = @target <> query
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: ^target}}
      refute_receive {:http_request, _}, 20
    end
  end

  test "defaults to configured signing wallet while an explicit list address selects a separate target" do
    base = server(@page)
    System.put_env("WALLET_ADDRESS", base <> "/default-wallet")
    assert {_, "", 0} = invoke(["incoming", "list", "--allow-http"])
    assert_received {:http_request, %{target: "/default-wallet"}}
    assert_received {:http_request, %{target: @target}}

    assert {_, "", 0} =
             invoke([
               "incoming",
               "list",
               "--wallet-address",
               base <> "/override-wallet",
               "--allow-http"
             ])

    assert_received {:http_request, %{target: "/override-wallet"}}
    assert_received {:http_request, %{target: @target}}

    assert {_, "", 0} =
             invoke(
               arguments(base <> "/target-wallet") ++
                 ["--wallet-address", "$client.example/other"]
             )

    assert_received {:http_request, %{target: "/target-wallet"}}
    assert_received {:http_request, %{target: @target}}
    refute_receive {:http_request, _}, 20
  end

  test "reuses token-file and signing override precedence", %{directory: directory, key: key} do
    base = server(@page)
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-key")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-invalid-key")
    System.put_env("ACCESS_TOKEN", "invalid env token")
    token = Path.join(directory, "token.txt")
    File.write!(token, "file-list-token\r\n")

    assert {stdout, "", 0} =
             invoke(
               arguments(base <> "/receiver") ++
                 [
                   "--access-token-file",
                   token,
                   "--wallet-address",
                   "$client.example/other",
                   "--key-id",
                   "override-id",
                   "--key-file",
                   key
                 ]
             )

    refute stdout =~ "file-list-token"
    assert_received {:http_request, %{target: "/receiver"}}
    assert_received {:http_request, %{headers: headers, target: @target}}
    assert headers["authorization"] == "GNAP file-list-token"
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert File.read!(token) == "file-list-token\r\n"
    assert File.read!(key) == @pem
  end

  test "invalid pagination is rejected before discovery without echoing the cursor" do
    base = server(@page)

    for flags <- [
          ["--first", "0"],
          ["--first", "101"],
          ["--last", "-1"],
          ["--last", "101"],
          ["--first", "1", "--last", "1"],
          ["--cursor", ""],
          ["--first", "1.5"],
          ["--first", "private-invalid-number"],
          ["--first", "0", "--cursor", "private-cursor"]
        ] do
      assert {"", stderr, 2} = invoke(arguments(base <> "/receiver") ++ flags)
      refute stderr =~ "private-"
    end

    refute_receive {:http_request, _}, 20
  end

  test "missing credentials and invalid wallet addresses fail safely before HTTP", %{
    directory: directory
  } do
    base = server(@page)

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", stderr, 2} = invoke(arguments(base <> "/receiver"))
      assert stderr =~ "Supply"
      System.put_env(name, previous)
    end

    assert {"", stderr, 2} =
             invoke(
               arguments(base <> "/receiver") ++
                 ["--access-token-file", Path.join(directory, "private-missing-token")]
             )

    refute stderr =~ "private-"

    for address <- [
          "",
          "relative-private-wallet",
          "https://user:private-password@wallet.example/receiver"
        ] do
      assert {"", stderr, 2} = invoke(arguments(address))
      refute stderr =~ "private-"
    end

    assert {"", stderr, 2} = invoke(["incoming", "list", base <> "/receiver"])
    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
  end

  test "discovery errors and invalid resource-server URLs never produce a signed list request" do
    for response <- [{401, [], "private-error"}, {200, [], "private-invalid-response"}] do
      base = HTTPServer.start(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/receiver"))
      assert stderr =~ "Wallet discovery"
      refute stderr =~ "private-"
      assert_received {:http_request, %{target: "/receiver"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end

    base = server(@page, "/tenant?private-query=1")
    assert {"", stderr, 2} = invoke(arguments(base <> "/receiver"))
    refute stderr =~ "private-query"
    assert_received {:http_request, %{target: "/receiver"}}
    refute_receive {:http_request, _}, 20
  end

  test "HTTP errors and transport failures do not retry or follow redirects" do
    for response <- [
          {302, [{"Location", "https://payments.example/next"}], "private-error"},
          {401, [], "private-error"},
          {503, [], "private-error"},
          :close
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/receiver"))
      assert stderr =~ "Incoming-payment listing failed"
      refute stderr =~ "private-"
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "invalid pages and asset mismatches remain SDK errors without partial results" do
    for response <- [
          {200, [], "private-invalid-json"},
          {201, [], Jason.encode!(@page)},
          {200, [], Jason.encode!(Map.delete(@page, "pagination"))},
          {200, [], Jason.encode!(put_in(@page, ["result"], [Map.put(@payment, "methods", [])]))},
          {200, [],
           Jason.encode!(
             put_in(@page, ["result"], [put_in(@payment, ["incomingAmount", "assetCode"], "EUR")])
           )}
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/receiver"))
      assert stderr == "Error: Incoming-payment listing returned an invalid response.\n"
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "pagination flags are scoped strictly to incoming list and help stays offline" do
    for args <- [
          ["incoming", "list", "https://wallet.example/receiver", "extra"],
          ["incoming", "list", "--all"],
          ["incoming", "list", "--first"],
          ["incoming", "list", "--access-token", "private-token"],
          ["incoming", "list", "--output", "private-file"],
          ["incoming", "list", "--jwks"],
          ["incoming", "list", "--version"],
          ["incoming", "get", "https://payments.example/id", "--first", "2"],
          ["incoming", "create", "-", "--cursor", "private-cursor"],
          ["grant", "request", "-", "--last", "2"],
          ["keys", "validate", "--first", "2"]
        ] do
      assert {"", stderr, 2} = invoke(args)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["incoming", "list", "--help"])
    assert stdout =~ "incoming list [address]"
    assert stdout =~ "--first"
    assert stdout =~ "--last"
    assert stdout =~ "--cursor"
    refute_received {:http_request, _}
  end

  defp arguments(address), do: ["incoming", "list", address, "--allow-http"]

  defp server(response, endpoint \\ "/tenant%2falpha") do
    HTTPServer.start(fn wire ->
      if Map.has_key?(wire.headers, "authorization") do
        if is_map(response), do: {200, [], Jason.encode!(response)}, else: response
      else
        base = "http://" <> wire.headers["host"]

        {200, [],
         Jason.encode!(%{
           "id" => @wallet,
           "assetCode" => "USD",
           "assetScale" => 2,
           "authServer" => "https://auth.example/tenant",
           "resourceServer" => base <> endpoint
         })}
      end
    end)
  end

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
