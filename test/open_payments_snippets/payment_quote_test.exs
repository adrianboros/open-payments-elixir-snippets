defmodule OpenPaymentsSnippets.PaymentQuoteTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.PaymentQuote
  alias OpenPaymentsSnippets.Test.HTTPServer

  # Public RFC 8032 test vector 1.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-payment-quote-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      "ACCESS_TOKEN" => "wrong-resource-token"
    })

    %{directory: directory, key: key, path: Path.join(directory, "session.json")}
  end

  test "creates one fixed-receive quote with the saved latest sender token and preserves grant state",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        saved = load(path)
        assert saved["state"] == "in-flight" and saved["attempt_operation"] == "payment-quote"
        assert saved["payment"]["stage"] == "sender-grant"
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(path <> ".lock").mode &&& 0o777) == 0o600
        assert wire.method == :POST and wire.target == "/tenant%2falpha/quotes"
        assert wire.headers["authorization"] == "GNAP test-sender-rotated-secret"
        assert valid_signature?(wire)
        json(201, quote_data(origin(wire)))
      end)

    original =
      authorized(base)
      |> put_in(["response", "access_token", "value"], "test-sender-rotated-secret")
      |> Map.put("token_rotation_response", %{
        "access_token" => token(base, "test-sender-rotated-secret")
      })
      |> Map.put("token_rotated_at", "2026-11-19T00:00:00Z")

    write(c.path, original)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, true)
    saved = load(c.path)
    assert saved["state"] == "ready" and saved["payment"]["stage"] == "quote-ready"
    assert saved["payment"]["quote"] == quote_data(base)
    assert {:ok, _, _} = DateTime.from_iso8601(saved["payment"]["quote_created_at"])
    assert Map.delete(saved, "payment") == Map.delete(original, "payment")

    assert Map.drop(saved["payment"], ~w(stage quote quote_created_at)) ==
             Map.drop(original["payment"], ["stage"])

    assert File.read!(c.path) =~ "test-quote-secret"
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    assert File.read!(c.key) == @pem
    assert_received {:http_request, wire}

    assert Jason.decode!(wire.body) == %{
             "walletAddress" => base <> "/sender",
             "receiver" => incoming(base)["id"],
             "method" => "ilp",
             "receiveAmount" => amount()
           }

    assert wire.headers["content-length"] == Integer.to_string(byte_size(wire.body))
    refute valid_signature?(%{wire | body: wire.body <> " "})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed"))
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.directory), &String.contains?(&1, ".tmp-"))
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, false)
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  test "text output quotes the URL and shows both core amounts without private amount extensions",
       c do
    base = HTTPServer.start(fn wire -> json(201, quote_data(origin(wire))) end)
    write(c.path, authorized(base))
    assert {stdout, "", 0} = invoke(args(c.path))
    result = summary(c.path, base, true)

    assert stdout ==
             "Payment quote ready\nStage  quote-ready\nSession  #{Jason.encode!(c.path)}\nQuote  #{Jason.encode!(result["quote_url"])}\nDebit amount  #{Jason.encode!(result["debit_amount"])}\nReceive amount  #{Jason.encode!(result["receive_amount"])}\n"

    refute stdout =~ "expiresAt"
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "cached quotes remain available after token revocation without a replacement quote", c do
    base =
      HTTPServer.start(fn wire ->
        if wire.method == :DELETE, do: {204, [], ""}, else: json(201, quote_data(origin(wire)))
      end)

    write(c.path, authorized(base))
    assert {_, "", 0} = invoke(args(c.path))
    assert {_, "", 0} = invoke(["token", "revoke", c.path, "--allow-http"])
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, false)
    assert File.read!(c.path) == before
    assert load(c.path)["payment"]["quote"]["expiresAt"] == "opaque-expiry-string"
    assert_received {:http_request, %{method: :POST}}
    assert_received {:http_request, %{method: :DELETE}}
    refute_receive {:http_request, _}, 20
  end

  test "wallet discovery through sender consent and rotation produces one saved quote without outgoing creation",
       c do
    base =
      HTTPServer.start(fn wire ->
        base = origin(wire)

        case wire.target do
          "/sender" ->
            json(200, wallet(base, "sender"))

          "/receiver" ->
            json(200, wallet(base, "receiver"))

          "/auth/receiver?part=a%2Bb" ->
            json(200, prepared(base)["response"])

          "/tenant%2falpha/incoming-payments" ->
            json(201, incoming(base))

          "/auth/sender?part=a%2Bb" ->
            json(200, pending(base))

          "/continue/sender?part=a%2Bb" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-sender-cont-secret"
            if wire.method == :DELETE, do: {204, [], ""}, else: json(200, approved(base))

          "/manage/sender?part=a%2Bb" ->
            assert wire.headers["authorization"] == "GNAP test-sender-issued-secret"
            json(200, %{"access_token" => token(base, "test-sender-rotated-secret")})

          "/tenant%2falpha/quotes" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-sender-rotated-secret"
            json(201, quote_data(base))
        end
      end)

    System.put_env("WALLET_ADDRESS", base <> "/sender")

    initial = %{
      "receiver" => base <> "/receiver",
      "receiveAmount" => amount(),
      "finishUri" => "https://client.example/receiver-return?state=receiver"
    }

    assert {_, "", 0} =
             invoke(
               ["payment", "start", "-", "--output", c.path, "--allow-http"],
               Jason.encode!(initial)
             )

    assert {_, "", 0} = invoke(["payment", "prepare", c.path, "--allow-http"])

    assert {_, "", 0} =
             invoke(
               ["payment", "authorize", c.path, "-", "--allow-http"],
               Jason.encode!(intent())
             )

    before = File.read!(c.path)
    assert {"", _, 2} = invoke(args(c.path))
    assert File.read!(c.path) == before
    sender = load(c.path)
    reference = "test-sender-reference"

    hash =
      :crypto.hash(
        :sha256,
        Enum.join(
          [sender["finish"]["nonce"], "test-sender-nonce", reference, sender["grant_endpoint"]],
          "\n"
        )
      )
      |> Base.encode64()

    callback = Path.join(c.directory, "callback.txt")

    File.write!(
      callback,
      sender["finish"]["uri"] <>
        "&" <> URI.encode_query(%{"hash" => hash, "interact_ref" => reference})
    )

    assert {_, "", 0} =
             invoke(["grant", "continue", c.path, "--callback-file", callback, "--allow-http"])

    assert {_, "", 0} = invoke(["token", "rotate", c.path, "--allow-http"])
    assert {_, "", 0} = invoke(args(c.path))
    before = File.read!(c.path)
    assert {_, "", 0} = invoke(args(c.path))
    assert {_, "", 0} = invoke(["payment", "prepare", c.path, "--allow-http"])

    assert {stdout, "", 0} =
             invoke(
               ["payment", "authorize", c.path, "-", "--allow-http", "--json"],
               Jason.encode!(intent())
             )

    assert Jason.decode!(stdout)["status"] == "approved" and
             Jason.decode!(stdout)["saved"] == false

    assert File.read!(c.path) == before
    assert load(c.path)["payment"]["stage"] == "quote-ready"
    assert {_, "", 0} = invoke(["grant", "cancel", c.path, "--allow-http"])
    assert load(c.path)["state"] == "cancelled"
    refute Map.has_key?(load(c.path), "payment")
    wires = drain()
    assert length(wires) == 9
    assert Enum.count(wires, &(&1.target == "/tenant%2falpha/quotes")) == 1
    refute Enum.any?(wires, &String.contains?(&1.target, "outgoing-payments"))
  end

  test "receiver, pending, wait-only and revoked sender stages cannot create a quote", c do
    base = HTTPServer.start({500, [], "private-server-body"})

    wait_only =
      authorized(base)
      |> Map.put("kind", "grant-continuation")
      |> update_in(["response"], &Map.delete(&1, "access_token"))

    for session <- [
          prepared(base),
          Map.put(authorized(base), "response", pending(base)),
          wait_only,
          Map.put(wait_only, "kind", "token-revocation")
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "damaged context and cached quote never trigger new quote creation", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    valid = authorized(base)

    for session <- [
          put_in(valid, ["payment", "incoming_payment"], %{}),
          put_in(valid, ["payment", "receiver_grant", "key_id"], "other"),
          put_in(
            valid,
            ["payment", "incoming_request", "walletAddress"],
            "https://other.example/wallet"
          ),
          put_in(valid, ["payment", "quote"], quote_data(base)),
          put_in(valid, ["payment", "stage"], "quote-ready"),
          valid
          |> put_in(["payment", "stage"], "quote-ready")
          |> put_in(["payment", "quote"], %{})
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "explicit identity mismatch rejects while matching flags override conflicting environment",
       c do
    base = HTTPServer.start(fn wire -> json(201, quote_data(origin(wire))) end)
    write(c.path, authorized(base))
    before = File.read!(c.path)

    for flags <- [
          ["--key-id", "other"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", "missing-private-file"]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ flags)
      assert File.read!(c.path) == before
    end

    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    System.put_env("PRIVATE_KEY_FILE", "missing-private-file")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-private-source")

    assert {_, "", 0} =
             invoke(
               args(c.path) ++
                 [
                   "--key-file",
                   c.key,
                   "--key-id",
                   "test-key",
                   "--wallet-address",
                   "https://client.example/signer"
                 ]
             )

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "known SDK preflight failures leave the sender session unchanged", c do
    for change <- [
          fn s ->
            put_in(
              s,
              ["payment", "sender_wallet", "resourceServer"],
              "https://user:private-password@payments.example/base"
            )
          end,
          fn s -> put_in(s, ["response", "access_token", "value"], "invalid token") end,
          fn s -> put_in(s, ["payment", "incoming_payment", "id"], "urn:unsupported:incoming") end
        ] do
      session = change.(authorized("https://payments.example"))
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "ambiguous creation failures preserve grants and block all replay", c do
    for response <- [
          {302, [{"Location", "https://other.example/next"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {201, [], "not-json"},
          {201, [], "{}"},
          json(200, quote_data("https://payments.example"))
        ] do
      base = HTTPServer.start(response)
      original = authorized(base)
      write(c.path, original)
      assert {"", _, 1} = invoke(args(c.path))
      saved = load(c.path)
      assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-quote"

      assert Map.drop(saved, ~w(state attempted_at attempt_operation)) ==
               Map.drop(original, ["state"])

      assert {"", _, 2} = invoke(args(c.path))

      for command <- [
            ["payment", "prepare"],
            ["grant", "continue"],
            ["grant", "cancel"],
            ["token", "rotate"],
            ["token", "revoke"]
          ] do
        assert {"", _, 2} = invoke(command ++ [c.path, "--allow-http"])
      end

      assert {"", _, 2} =
               invoke(
                 ["payment", "authorize", c.path, "-", "--allow-http"],
                 Jason.encode!(intent())
               )

      assert_received {:http_request, %{method: :POST, target: "/tenant%2falpha/quotes"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "concurrent quote and token operations share the private lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, quote_data(origin(wire))))
      end)

    write(c.path, authorized(base))
    task = Task.async(fn -> PaymentQuote.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(args(c.path))
    assert {"", _, 1} = invoke(["token", "rotate", c.path, "--allow-http"])
    send(server, :release)
    assert {:ok, %{stage: "quote-ready"}} = Task.await(task)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed quote leaves its in-flight marker and stale lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, quote_data(origin(wire))))
      end)

    write(c.path, authorized(base))
    {pid, monitor} = spawn_monitor(fn -> PaymentQuote.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert load(c.path)["state"] == "in-flight" and
             load(c.path)["attempt_operation"] == "payment-quote"

    assert {"", _, 1} = invoke(args(c.path))
    send(server, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "pre-request and post-response persistence failures cannot report a saved quote", c do
    base = HTTPServer.start(fn wire -> json(201, quote_data(origin(wire))) end)
    path = Path.join(c.directory, String.duplicate("s", 240))
    write(path, authorized(base))
    before = File.read!(path)
    assert {"", _, 1} = invoke(args(path))
    assert File.read!(path) == before
    refute_receive {:http_request, _}, 20
    stop_supervised!(Task)
    parent = Path.join(c.directory, "private")
    moved = Path.join(c.directory, "moved")
    File.mkdir!(parent)
    path = Path.join(parent, "session.json")

    base =
      HTTPServer.start(fn wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        json(201, quote_data(origin(wire)))
      end)

    write(path, authorized(base))
    assert {"", _, 1} = invoke(args(path))
    saved = load(Path.join(moved, "session.json"))
    assert saved["state"] == "in-flight" and saved["payment"]["stage"] == "sender-grant"
    refute Map.has_key?(saved["payment"], "quote")
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "private-file rules, stale locks and unrelated flags fail before quoting", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, authorized(base))
    before = File.read!(c.path)
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path))
    File.chmod!(c.path, 0o600)
    link = Path.join(c.directory, "link.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(c.path))
    File.rm!(link)
    File.write!(c.path <> ".lock", "interrupted")
    assert {"", _, 1} = invoke(args(c.path))
    assert File.read!(c.path <> ".lock") == "interrupted" and File.read!(c.path) == before

    for argv <- [
          ["payment", "quote"],
          ["payment", "quote", ""],
          args(c.path) ++ ["extra"],
          args(c.path) ++ ["--output", "private-output"],
          args(c.path) ++ ["--access-token-file", "private-token"],
          args(c.path) ++ ["--callback-file", "private-callback"],
          args(c.path) ++ ["--hash-encoding", "base64"],
          args(c.path) ++ ["--first", "1"],
          args(c.path) ++ ["--jwks"],
          args(c.path) ++ ["--version"]
        ] do
      assert {"", _, 2} = invoke(argv)
    end

    assert {stdout, "", 0} = invoke(["payment", "quote", "--help"])
    assert stdout =~ "payment quote <session>"
    refute_receive {:http_request, _}, 20
  end

  defp args(path), do: ["payment", "quote", path, "--allow-http"]

  defp authorized(base) do
    receiver = prepared(base)

    receiver
    |> Map.drop(~w(token_rotated_at token_rotation_response))
    |> Map.merge(%{
      "kind" => "grant-continuation",
      "grant_endpoint" => base <> "/auth/sender?part=a%2Bb",
      "finish" => %{
        "method" => "redirect",
        "uri" => intent()["finishUri"],
        "nonce" => "test-client-nonce"
      },
      "response" => approved(base)
    })
    |> put_in(["payment", "stage"], "sender-grant")
    |> put_in(["payment", "receiver_grant"], Map.delete(receiver, "payment"))
    |> put_in(["payment", "sender_authorization"], intent())
  end

  defp quote_data(base),
    do: %{
      "id" => base <> "/tenant%2falpha/quotes/id?opaque=a%2Bb",
      "walletAddress" => base <> "/sender",
      "receiver" => incoming(base)["id"],
      "debitAmount" => %{
        "value" => "150",
        "assetCode" => "USD",
        "assetScale" => 2,
        "sharedSecret" => "test-quote-secret"
      },
      "receiveAmount" => %{amount() | "value" => "00000100"},
      "method" => "ilp",
      "createdAt" => "2026-11-19T10:20:30.123456+02:00",
      "expiresAt" => "opaque-expiry-string"
    }

  defp summary(path, base, saved?),
    do: %{
      "status" => "ready",
      "stage" => "quote-ready",
      "saved" => saved?,
      "session" => path,
      "quote_url" => quote_data(base)["id"],
      "debit_amount" => Map.drop(quote_data(base)["debitAmount"], ["sharedSecret"]),
      "receive_amount" => quote_data(base)["receiveAmount"]
    }

  defp intent,
    do: %{
      "debitAmount" => %{"value" => "200", "assetCode" => "USD", "assetScale" => 2},
      "finishUri" => "https://client.example/sender-return?state=sender"
    }

  defp amount, do: %{"value" => "100", "assetCode" => "EUR", "assetScale" => 2}
  defp origin(wire), do: "http://" <> wire.headers["host"]

  defp json(status, data),
    do: {status, [{"Content-Type", "application/json"}], Jason.encode!(data)}

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp write(path, session) do
    File.write!(path, Jason.encode!(session, pretty: true) <> "\n")
    File.chmod!(path, 0o600)
  end

  defp access(base),
    do: [
      %{"type" => "quote", "actions" => ["create", "read"]},
      %{
        "type" => "outgoing-payment",
        "actions" => ["create", "read"],
        "identifier" => base <> "/sender",
        "limits" => %{
          "debitAmount" => intent()["debitAmount"],
          "receiver" => incoming(base)["id"]
        }
      }
    ]

  defp wallet(base, role),
    do: %{
      "id" => base <> "/" <> role,
      "assetCode" => if(role == "sender", do: "USD", else: "EUR"),
      "assetScale" => 2,
      "authServer" => base <> "/auth/" <> role <> "?part=a%2Bb",
      "resourceServer" => base <> "/tenant%2falpha"
    }

  defp token(base, value),
    do: %{
      "value" => value,
      "manage" => base <> "/manage/sender?part=a%2Bb",
      "access" => access(base)
    }

  defp pending(base),
    do: %{
      "continue" => approved(base)["continue"],
      "interact" => %{"redirect" => base <> "/consent/sender", "finish" => "test-sender-nonce"},
      "extension" => "private-server-body"
    }

  defp approved(base),
    do: %{
      "continue" => %{
        "uri" => base <> "/continue/sender?part=a%2Bb",
        "access_token" => %{"value" => "test-sender-cont-secret"},
        "wait" => 0
      },
      "access_token" => token(base, "test-sender-issued-secret")
    }

  defp prepared(base) do
    %{
      "version" => 1,
      "kind" => "grant-request",
      "state" => "ready",
      "wallet_address" => "https://client.example/signer",
      "key_id" => "test-key",
      "signing_jwk" => %{
        "kid" => "test-key",
        "kty" => "OKP",
        "crv" => "Ed25519",
        "alg" => "EdDSA",
        "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
      },
      "grant_endpoint" => base <> "/auth/receiver?part=a%2Bb",
      "received_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "callback_verified" => true,
      "finish" => %{
        "method" => "redirect",
        "uri" => "https://client.example/receiver-return?state=receiver",
        "nonce" => "test-client-nonce"
      },
      "token_rotated_at" => "2026-11-19T00:00:00Z",
      "token_rotation_response" => %{"private-extension" => "private-server-body"},
      "response" => %{
        "continue" => %{
          "uri" => base <> "/continue/receiver?part=a%2Bb",
          "access_token" => %{"value" => "test-continuation-secret"},
          "wait" => 0
        },
        "access_token" => %{
          "value" => "test-issued-secret",
          "manage" => base <> "/manage/receiver",
          "access" => []
        }
      },
      "payment" => %{
        "version" => 1,
        "stage" => "incoming-ready",
        "incoming_request" => %{
          "walletAddress" => base <> "/receiver",
          "incomingAmount" => amount()
        },
        "sender_wallet" => wallet(base, "sender"),
        "receiver_wallet" => wallet(base, "receiver"),
        "incoming_payment" => incoming(base)
      }
    }
  end

  defp incoming(base),
    do: %{
      "id" => base <> "/tenant%2falpha/incoming-payments/id?opaque=a%2Bb",
      "walletAddress" => base <> "/receiver",
      "completed" => false,
      "incomingAmount" => amount(),
      "receivedAmount" => %{amount() | "value" => "0"},
      "createdAt" => "2026-11-19T10:20:30.123456+02:00",
      "methods" => [
        %{
          "type" => "ilp",
          "ilpAddress" => "g.example.receiver",
          "sharedSecret" => "test-ilp-secret"
        }
      ],
      "metadata" => %{"nested" => [%{"sharedSecret" => "test-metadata-secret"}]},
      "extension" => "private-server-body"
    }

  defp drain do
    receive do
      {:http_request, wire} -> [wire | drain()]
    after
      0 -> []
    end
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
          if(wire.headers["authorization"],
            do: ~s("authorization": #{wire.headers["authorization"]})
          ),
          if(wire.body != "", do: ~s("content-digest": #{wire.headers["content-digest"]})),
          if(wire.body != "", do: ~s("content-length": #{wire.headers["content-length"]})),
          if(wire.body != "", do: ~s("content-type": #{wire.headers["content-type"]})),
          ~s("@signature-params": #{params})
        ]
        |> Enum.reject(&is_nil/1),
        "\n"
      )

    public = Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)

    (wire.body == "" or digest == wire.headers["content-digest"]) and
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

    for secret <- [
          "test-continuation-secret",
          "test-issued-secret",
          "test-quote-secret",
          "test-sender-issued-secret",
          "test-sender-cont-secret",
          "test-sender-rotated-secret",
          "test-sender-nonce",
          "test-rotated-secret",
          "test-ilp-secret",
          "test-metadata-secret",
          "test-server-nonce",
          "private-server-body",
          "PRIVATE KEY",
          "wrong-resource-token"
        ] do
      refute stdout <> stderr =~ secret
    end

    {stdout, stderr, status}
  end
end
