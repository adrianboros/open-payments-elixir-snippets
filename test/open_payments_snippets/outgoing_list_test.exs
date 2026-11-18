defmodule OpenPaymentsSnippets.OutgoingListTest do
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
    "id" => "https://payments.example/tenant/outgoing-payments/id",
    "walletAddress" => @wallet,
    "receiver" => "https://receiver.example/incoming-payments/id",
    "failed" => false,
    "debitAmount" => @amount,
    "receiveAmount" => %{"value" => "000007", "assetCode" => "EUR", "assetScale" => 3},
    "sentAmount" => %{@amount | "value" => "000001"},
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
    "result" => [@payment, Map.put(@payment, "failed", true), @payment],
    "extension" => %{"sharedSecret" => "test-page-secret", "keep" => true}
  }
  @target "/tenant%2falpha/outgoing-payments?wallet-address=https%3A%2F%2Fwallet.example%2Freceiver"

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-outgoing-list-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-outgoing-list-token"
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

    assert headers["authorization"] == "GNAP test-outgoing-list-token"
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
      assert Enum.map(result["result"], & &1["failed"]) == [false, true, false]
      assert hd(result["result"]) == List.last(result["result"])
      assert hd(result["result"])["debitAmount"] == @amount
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
    assert {_, "", 0} = invoke(["outgoing", "list", "--allow-http"])
    assert_received {:http_request, %{target: "/default-wallet"}}
    assert_received {:http_request, %{target: @target}}

    assert {_, "", 0} =
             invoke([
               "outgoing",
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
    File.write!(token, "file-outgoing-list-token\r\n")

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

    refute stdout =~ "file-outgoing-list-token"
    assert_received {:http_request, %{target: "/receiver"}}
    assert_received {:http_request, %{headers: headers, target: @target}}
    assert headers["authorization"] == "GNAP file-outgoing-list-token"
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert File.read!(token) == "file-outgoing-list-token\r\n"
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

    assert {"", stderr, 2} = invoke(["outgoing", "list", base <> "/receiver"])
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
      assert stderr =~ "Outgoing-payment listing failed"
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
          {200, [],
           Jason.encode!(
             put_in(@page, ["result"], [Map.put(@payment, "grantSpentDebitAmount", @amount)])
           )},
          {200, [],
           Jason.encode!(
             put_in(@page, ["result"], [put_in(@payment, ["sentAmount", "assetCode"], "EUR")])
           )}
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/receiver"))
      assert stderr == "Error: Outgoing-payment listing returned an invalid response.\n"
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "a later inconsistent item fails the entire page without partial output" do
    for invalid <- [
          @payment
          |> put_in(["debitAmount", "value"], "18446744073709551614")
          |> put_in(["sentAmount", "value"], "18446744073709551615"),
          @payment |> put_in(["sentAmount", "value"], @amount["value"]) |> Map.put("failed", true)
        ] do
      base = server(put_in(@page, ["result"], [@payment, invalid]))
      assert {"", stderr, 1} = invoke(arguments(base <> "/receiver"))
      assert stderr == "Error: Outgoing-payment listing returned an invalid response.\n"
      assert_received {:http_request, %{target: "/receiver"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "all amount extensions are redacted and distinct receive assets and decimal spelling survive" do
    payment =
      @payment
      |> put_in(["debitAmount", "sharedSecret"], "test-debit-secret")
      |> put_in(["sentAmount", "nested"], [%{"sharedSecret" => "test-sent-secret"}])
      |> put_in(["receiveAmount", "sharedSecret"], "test-receive-secret")

    base = server(put_in(@page, ["result"], [payment]))
    assert {stdout, "", 0} = invoke(arguments(base <> "/receiver") ++ ["--json"])
    [result] = Jason.decode!(stdout)["result"]
    assert result["debitAmount"]["value"] == @amount["value"]
    assert result["sentAmount"]["value"] == "000001"
    assert result["receiveAmount"]["value"] == "000007"
    assert result["receiveAmount"]["assetCode"] == "EUR"
    assert result["debitAmount"]["sharedSecret"] == "[REDACTED]"
    assert result["sentAmount"]["nested"] == [%{"sharedSecret" => "[REDACTED]"}]
    assert result["receiveAmount"]["sharedSecret"] == "[REDACTED]"
    refute stdout =~ "test-"
    assert_received {:http_request, %{target: "/receiver"}}
    assert_received {:http_request, %{target: @target}}
    refute_receive {:http_request, _}, 20
  end

  test "pagination flags are scoped strictly to list commands and help stays offline" do
    for args <- [
          ["outgoing", "list", "https://wallet.example/receiver", "extra"],
          ["outgoing", "list", "--all"],
          ["outgoing", "list", "--first"],
          ["outgoing", "list", "--access-token", "private-token"],
          ["outgoing", "list", "--output", "private-file"],
          ["outgoing", "list", "--jwks"],
          ["outgoing", "list", "--version"],
          ["outgoing", "list", "--callback-file", "private-callback"],
          ["outgoing", "get", "https://payments.example/id", "--first", "2"],
          ["outgoing", "create", "-", "--cursor", "private-cursor"],
          ["incoming", "get", "https://payments.example/id", "--first", "2"],
          ["incoming", "create", "-", "--cursor", "private-cursor"],
          ["grant", "request", "-", "--last", "2"],
          ["keys", "validate", "--first", "2"]
        ] do
      assert {"", stderr, 2} = invoke(args)
      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["outgoing", "list", "--help"])
    assert stdout =~ "outgoing list [address]"
    assert stdout =~ "--first"
    assert stdout =~ "--last"
    assert stdout =~ "--cursor"
    refute_received {:http_request, _}
  end

  defp arguments(address), do: ["outgoing", "list", address, "--allow-http"]

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
