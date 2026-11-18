defmodule OpenPaymentsSnippets.OutgoingGrantSpentTest do
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
  @wallet "https://wallet.example/canonical-owner?opaque=a%2Bb"
  @debit %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "000007", "assetCode" => "EUR", "assetScale" => 3}
  @spent %{"spentDebitAmount" => @debit, "spentReceiveAmount" => @receive}
  @target "/tenant%2falpha/outgoing-payment-grant"

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-outgoing-spent-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "test-spent-token"
    })

    %{directory: directory, key: key}
  end

  test "discovers the selected resource server and signs exactly one bodyless spent read with no filter" do
    base = server(@spent)
    assert {stdout, "", 0} = invoke(arguments(base <> "/selected-wallet"))
    assert Jason.decode!(stdout) == @spent

    assert_received {:http_request,
                     %{method: :GET, target: "/selected-wallet", headers: discovery}}

    refute Map.has_key?(discovery, "authorization")
    refute Map.has_key?(discovery, "signature")

    assert_received {:http_request,
                     %{method: :GET, target: @target, body: "", headers: headers} = wire}

    assert headers["authorization"] == "GNAP test-spent-token"
    assert headers["accept"] == "application/json"
    refute Map.has_key?(headers, "content-type")
    refute Map.has_key?(headers, "content-digest")
    assert valid_signature?(wire)
    refute valid_signature?(%{wire | target: @target <> "?wallet-address=unexpected"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed-token"))
    refute stdout =~ "test-spent-token"
    refute_receive {:http_request, _}, 20
  end

  test "both required nullable fields retain their presence and decimal asset data without defaults" do
    for response <- [
          @spent,
          %{"spentDebitAmount" => nil, "spentReceiveAmount" => @receive},
          %{"spentDebitAmount" => @debit, "spentReceiveAmount" => nil},
          %{"spentDebitAmount" => nil, "spentReceiveAmount" => nil}
        ] do
      base = server(response, "/tenant%2falpha/")

      for flags <- [[], ["--json"]] do
        assert {stdout, "", 0} = invoke(arguments(base <> "/selected-wallet") ++ flags)
        assert Jason.decode!(stdout) == response
        if flags == [], do: assert(stdout =~ "\n "), else: refute(stdout =~ "\n ")
        assert_received {:http_request, %{target: "/selected-wallet"}}
        assert_received {:http_request, %{target: @target}}
        refute_receive {:http_request, _}, 20
      end

      stop_supervised!(Task)
    end
  end

  test "SDK extensions are preserved while shared secrets are recursively redacted" do
    response =
      @spent
      |> put_in(["spentDebitAmount", "sharedSecret"], "test-debit-secret")
      |> put_in(["spentReceiveAmount", "nested"], [
        %{"sharedSecret" => "test-receive-secret", "keep" => true}
      ])
      |> Map.put("sharedSecret", "test-root-secret")
      |> Map.put("extension", [
        %{"sharedSecret" => "test-extension-secret", "interval" => "server-value"}
      ])

    base = server(response)

    for flags <- [[], ["--json"]] do
      assert {stdout, "", 0} = invoke(arguments(base <> "/selected-wallet") ++ flags)
      result = Jason.decode!(stdout)
      assert result["spentDebitAmount"]["value"] == @debit["value"]
      assert result["spentReceiveAmount"]["value"] == "000007"
      assert result["spentReceiveAmount"]["assetCode"] == "EUR"
      assert result["spentDebitAmount"]["sharedSecret"] == "[REDACTED]"

      assert result["spentReceiveAmount"]["nested"] == [
               %{"sharedSecret" => "[REDACTED]", "keep" => true}
             ]

      assert result["sharedSecret"] == "[REDACTED]"

      assert result["extension"] == [
               %{"sharedSecret" => "[REDACTED]", "interval" => "server-value"}
             ]

      refute stdout =~ "test-"
      assert_received {:http_request, %{target: "/selected-wallet"}}
      assert_received {:http_request, %{target: @target}}
    end

    refute_receive {:http_request, _}, 20
  end

  test "default and overridden discovery wallets remain separate from an explicit target" do
    base = server(@spent)
    System.put_env("WALLET_ADDRESS", base <> "/default-wallet")
    assert {_, "", 0} = invoke(["outgoing", "grant-spent-amounts", "--allow-http"])
    assert_received {:http_request, %{target: "/default-wallet"}}
    assert_received {:http_request, %{target: @target}}

    assert {_, "", 0} =
             invoke([
               "outgoing",
               "grant-spent-amounts",
               "--wallet-address",
               base <> "/override-wallet",
               "--allow-http"
             ])

    assert_received {:http_request, %{target: "/override-wallet"}}
    assert_received {:http_request, %{target: @target}}

    assert {_, "", 0} =
             invoke(
               arguments(base <> "/selected-wallet") ++
                 ["--wallet-address", "$client.example/other"]
             )

    assert_received {:http_request, %{target: "/selected-wallet"}}
    assert_received {:http_request, %{target: @target}}
    refute_receive {:http_request, _}, 20
  end

  test "token files and matching signing overrides retain precedence and source integrity", c do
    base = server(@spent)
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-key")
    System.put_env("PRIVATE_KEY_FILE", "/missing-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-invalid-key")
    System.put_env("ACCESS_TOKEN", "invalid env token")
    path = Path.join(c.directory, "token.txt")

    for ending <- ["", "\n", "\r\n"] do
      File.write!(path, "file-spent-token" <> ending)

      assert {_, "", 0} =
               invoke(
                 arguments(base <> "/selected-wallet") ++
                   [
                     "--access-token-file",
                     path,
                     "--wallet-address",
                     "$client.example/other",
                     "--key-id",
                     "override-id",
                     "--key-file",
                     c.key
                   ]
               )

      assert_received {:http_request, %{target: "/selected-wallet"}}
      assert_received {:http_request, %{target: @target, headers: headers} = wire}
      assert headers["authorization"] == "GNAP file-spent-token"
      assert headers["signature-input"] =~ ~s(keyid="override-id")
      assert valid_signature?(wire)
      assert File.read!(path) == "file-spent-token" <> ending
    end

    assert File.read!(c.key) == @pem
    refute_receive {:http_request, _}, 20
  end

  test "base64 PEM signing settings work for spent reads" do
    base = server(@spent)
    System.delete_env("PRIVATE_KEY_FILE")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))
    assert {_, "", 0} = invoke(arguments(base <> "/selected-wallet"))
    assert_received {:http_request, %{target: "/selected-wallet"}}
    assert_received {:http_request, %{target: @target}}
    refute_receive {:http_request, _}, 20
  end

  test "missing configuration and unreadable tokens fail before discovery, invalid tokens before signed HTTP",
       c do
    base = server(@spent)

    for name <- ~w(ACCESS_TOKEN WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", _, 2} = invoke(arguments(base <> "/selected-wallet"))
      System.put_env(name, previous)
    end

    assert {"", stderr, 2} =
             invoke(
               arguments(base <> "/selected-wallet") ++
                 ["--access-token-file", Path.join(c.directory, "private-missing-token")]
             )

    refute stderr =~ "private-"
    refute_receive {:http_request, _}, 20
    System.put_env("ACCESS_TOKEN", "private invalid token")
    assert {"", stderr, 2} = invoke(arguments(base <> "/selected-wallet"))
    refute stderr =~ "private"
    assert_received {:http_request, %{target: "/selected-wallet"}}
    refute_receive {:http_request, _}, 20
  end

  test "invalid discovery wallets and missing HTTP opt-in fail without a request" do
    base = server(@spent)

    for address <- [
          "",
          "relative-private-wallet",
          "https://user:private-password@wallet.example/id"
        ] do
      assert {"", stderr, 2} = invoke(arguments(address))
      refute stderr =~ "private-"
    end

    assert {"", stderr, 2} =
             invoke(["outgoing", "grant-spent-amounts", base <> "/selected-wallet"])

    assert stderr =~ "local HTTP requires --allow-http"
    refute_receive {:http_request, _}, 20
  end

  test "discovery failures stop before a grant read and omit response bodies" do
    for response <- [{401, [], "private-error"}, {200, [], "private-invalid-response"}] do
      base = HTTPServer.start(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/selected-wallet"))
      assert stderr =~ "Wallet discovery"
      refute stderr =~ "private-"
      assert_received {:http_request, %{target: "/selected-wallet"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "SDK rejects queried and unsafe resource-server bases without a signed request" do
    for endpoint <- [
          "/tenant?private-query=1",
          "/tenant?",
          "https://user:private-password@payments.example/tenant"
        ] do
      base = server(@spent, endpoint)
      assert {"", stderr, 2} = invoke(arguments(base <> "/selected-wallet"))
      refute stderr =~ "private-"
      assert_received {:http_request, %{target: "/selected-wallet"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "HTTP and transport errors never retry, redirect or expose server bodies" do
    for response <- [
          {302, [{"Location", "https://payments.example/next"}], "private-error"},
          {401, [], "private-error"},
          {503, [], "private-error"},
          :close
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/selected-wallet"))
      assert stderr =~ "Outgoing grant-spent read failed"
      refute stderr =~ "private-"
      assert_received {:http_request, %{target: "/selected-wallet"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "missing fields, invalid amounts and unexpected success status reject all output" do
    for response <- [
          {200, [], "private-invalid-json"},
          {201, [], Jason.encode!(@spent)},
          {200, [], "[]"},
          {200, [], Jason.encode!(Map.delete(@spent, "spentDebitAmount"))},
          {200, [], Jason.encode!(%{"spentDebitAmount" => nil})},
          {200, [], Jason.encode!(put_in(@spent, ["spentReceiveAmount", "value"], 1.5))},
          {200, [], Jason.encode!(%{"spentDebitAmount" => %{}, "spentReceiveAmount" => nil})}
        ] do
      base = server(response)
      assert {"", stderr, 1} = invoke(arguments(base <> "/selected-wallet"))
      assert stderr == "Error: Outgoing grant-spent read returned an invalid response.\n"
      assert_received {:http_request, %{target: "/selected-wallet"}}
      assert_received {:http_request, %{target: @target}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "grant spent reads reject pagination, literal tokens, callbacks and output flags; help is offline" do
    for flags <- [
          ["extra"],
          ["--first", "1"],
          ["--last", "1"],
          ["--cursor", "private-cursor"],
          ["--access-token", "private-token"],
          ["--output", "private-file"],
          ["--callback-file", "private-callback"],
          ["--jwks"],
          ["--version"]
        ] do
      assert {"", stderr, 2} =
               invoke(["outgoing", "grant-spent-amounts", "https://wallet.example/id"] ++ flags)

      refute stderr =~ "private-"
    end

    assert {stdout, "", 0} = invoke(["outgoing", "grant-spent-amounts", "--help"])
    assert stdout =~ "outgoing grant-spent-amounts [address]"
    refute_received {:http_request, _}
  end

  defp arguments(address), do: ["outgoing", "grant-spent-amounts", address, "--allow-http"]

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
           "resourceServer" =>
             if(String.starts_with?(endpoint, "/"), do: base <> endpoint, else: endpoint)
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
