defmodule OpenPaymentsSnippets.PaymentFinishTest do
  use ExUnit.Case, async: false
  import OpenPaymentsSnippets.Test.PaymentMetadata
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.PaymentFinish
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
        "open-payments-finish-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  test "explicit automation confirmation submits exactly once with the latest sender token and durable state",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        saved = load(path)
        assert saved["state"] == "in-flight" and saved["attempt_operation"] == "payment-finish"
        assert saved["payment"]["stage"] == "quote-ready"
        assert saved["payment"]["outgoing_confirmation"] == "yes"

        assert_enriched(saved["payment"]["outgoing_request"], %{
          "walletAddress" => origin(wire) <> "/sender",
          "quoteId" => quote_data(origin(wire))["id"]
        })

        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(path <> ".lock").mode &&& 0o777) == 0o600
        assert wire.method == :POST and wire.target == "/tenant%2falpha/outgoing-payments"
        assert wire.headers["authorization"] == "GNAP test-sender-rotated-secret"
        assert valid_signature?(wire)
        json(201, outgoing(origin(wire)))
      end)

    original =
      quoted(base)
      |> put_in(["response", "access_token", "value"], "test-sender-rotated-secret")
      |> Map.put("token_rotation_response", %{
        "access_token" => token(base, "test-sender-rotated-secret")
      })

    write(c.path, original)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--yes", "--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, true)
    saved = load(c.path)
    assert saved["state"] == "ready" and saved["payment"]["stage"] == "outgoing-created"
    assert saved["payment"]["outgoing_payment"] == outgoing(base)
    assert saved["payment"]["outgoing_confirmation"] == "yes"

    for field <- ~w(outgoing_confirmed_at outgoing_created_at) do
      assert {:ok, _, _} = DateTime.from_iso8601(saved["payment"][field])
    end

    assert Map.delete(saved, "payment") == Map.delete(original, "payment")

    assert Map.drop(
             saved["payment"],
             ~w(stage outgoing_request outgoing_confirmation outgoing_confirmed_at outgoing_created_at outgoing_payment)
           ) == Map.drop(original["payment"], ["stage"])

    assert File.read!(c.path) =~ "test-outgoing-secret"
    assert File.read!(c.key) == @pem
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.directory), &String.contains?(&1, ".tmp-"))
    assert_received {:http_request, wire}
    assert Jason.decode!(wire.body) == saved["payment"]["outgoing_request"]
    refute valid_signature?(%{wire | body: wire.body <> " "})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed"))
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, false)
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  test "text confirmation previews the quote on stderr and records prompt consent", c do
    base = HTTPServer.start(fn wire -> json(201, outgoing(origin(wire))) end)
    write(c.path, quoted(base))
    assert {stdout, stderr, 0} = invoke(args(c.path), "send\n")
    assert stderr =~ "Type send to create the outgoing payment"
    assert stderr =~ "Sender  #{Jason.encode!(base <> "/sender")}"
    assert stderr =~ "Incoming payment  #{Jason.encode!(incoming(base)["id"])}"
    assert stderr =~ "Quote  #{Jason.encode!(quote_data(base)["id"])}"
    assert stderr =~ "Debit amount  #{Jason.encode!(core(quote_data(base)["debitAmount"]))}"
    assert stderr =~ "Receive amount  #{Jason.encode!(core(quote_data(base)["receiveAmount"]))}"
    assert stderr =~ "Quote expiry  #{Jason.encode!(quote_data(base)["expiresAt"])}"
    refute stdout =~ "Type send"
    assert stdout =~ "Outgoing payment created\nStage  outgoing-created"
    assert stdout =~ "Failed  false"
    assert stdout =~ "Sent amount"
    assert load(c.path)["payment"]["outgoing_confirmation"] == "prompt"
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "decline, blank input and EOF leave the quote unchanged and make no request", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, quoted(base))
    before = File.read!(c.path)

    for answer <- ["", "\n", "no\n", "yes\n", "send later\n"] do
      assert {stdout, stderr, 0} = invoke(args(c.path), answer)
      assert stdout == "Payment not sent\nStage  quote-ready\nSession  #{Jason.encode!(c.path)}\n"
      assert stderr =~ "Type send"
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "a quote above the requested maximum is rejected before confirmation or HTTP for finish and finalize",
       c do
    base = HTTPServer.start({500, [], "private-server-body"})

    session =
      quoted(base)
      |> put_in(["payment", "quote", "debitAmount", "value"], "249")
      |> put_in(["payment", "sender_authorization", "debitAmount", "value"], "137")
      |> put_in(
        ["response", "access_token", "access", Access.at(1), "limits", "debitAmount", "value"],
        "137"
      )

    session =
      put_in(session, ["payment", "scenario"], %{
        "version" => 1,
        "name" => "quote-payment",
        "sender_authorization" => session["payment"]["sender_authorization"]
      })

    write(c.path, session)
    before = File.read!(c.path)

    for command <- ["finish", "finalize"] do
      assert {"", stderr, 2} = invoke(["payment", command, c.path, "--allow-http"], "send\n")
      assert stderr =~ "249" and stderr =~ "137" and stderr =~ "No outgoing request was sent"
      refute stderr =~ "Type send"
      refute stderr =~ "test-quote-secret"
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_received {:http_request, _}
  end

  test "issued grant limits and permissions are checked even when the requested cap is sufficient",
       c do
    base = HTTPServer.start({500, [], "private-server-body"})
    original = quoted(base)
    access_path = ["response", "access_token", "access", Access.at(1)]

    for change <- [
          fn s -> put_in(s, access_path ++ ["limits", "debitAmount", "value"], "149") end,
          fn s -> put_in(s, access_path ++ ["limits", "debitAmount", "assetCode"], "GBP") end,
          fn s -> put_in(s, access_path ++ ["limits", "debitAmount", "assetScale"], 3) end,
          fn s ->
            put_in(s, access_path ++ ["limits", "receiver"], base <> "/incoming-payments/other")
          end,
          fn s -> put_in(s, access_path ++ ["identifier"], base <> "/other-wallet") end,
          fn s -> put_in(s, access_path ++ ["actions"], ["read"]) end,
          fn s -> put_in(s, ["response", "access_token", "access"], []) end,
          fn s ->
            put_in(s, access_path ++ ["limits"], %{
              "receiveAmount" => %{amount() | "value" => "99"}
            })
          end
        ] do
      write(c.path, change.(original))
      before = File.read!(c.path)
      assert {"", stderr, 2} = invoke(args(c.path) ++ ["--yes"])
      assert stderr =~ "issued token"
      refute stderr =~ "Type send"
      assert File.read!(c.path) == before
    end

    refute_received {:http_request, _}
  end

  test "debit comparisons preserve integer precision above floating point range", c do
    base = HTTPServer.start({500, [], "private-server-body"})

    for {cap, debit} <- [
          {"9007199254740992", "9007199254740993"},
          {"18446744073709551614", "18446744073709551615"}
        ] do
      session =
        quoted(base)
        |> put_in(["payment", "sender_authorization", "debitAmount", "value"], cap)
        |> put_in(["payment", "quote", "debitAmount", "value"], debit)

      write(c.path, session)
      assert {"", stderr, 2} = invoke(args(c.path) ++ ["--yes"])
      assert stderr =~ "requested maximum"
    end

    refute_received {:http_request, _}
  end

  test "an exact limit with leading zeros permits the quote and checks all matching issued entries",
       c do
    base = HTTPServer.start(fn wire -> json(201, outgoing(origin(wire))) end)

    session =
      quoted(base)
      |> put_in(["payment", "sender_authorization", "debitAmount", "value"], "00000150")
      |> put_in(
        ["response", "access_token", "access", Access.at(1), "limits", "debitAmount", "value"],
        "00000150"
      )

    narrow =
      List.last(session["response"]["access_token"]["access"])
      |> put_in(["limits", "debitAmount", "value"], "149")

    session = update_in(session, ["response", "access_token", "access"], &[narrow | &1])
    write(c.path, session)
    assert {_, "", 0} = invoke(args(c.path) ++ ["--yes", "--json"])
    assert load(c.path)["payment"]["stage"] == "outgoing-created"
    assert_received {:http_request, %{method: :POST}}
    refute_received {:http_request, _}
  end

  test "JSON creation requires explicit yes and false does not bypass confirmation", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, quoted(base))
    before = File.read!(c.path)

    for flags <- [["--json"], ["--json", "--no-yes"]] do
      assert {"", stderr, 2} = invoke(args(c.path) ++ flags, "send\n")
      assert stderr =~ "requires --yes"
      refute stderr =~ "Type send"
      assert File.read!(c.path) == before
    end

    assert {stdout, stderr, 0} = invoke(args(c.path) ++ ["--no-yes"], "no\n")
    assert stdout =~ "Payment not sent" and stderr =~ "Type send"
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  @tag :consumer_flow
  test "the complete flow creates one outgoing payment then allows cached results, revocation and cancellation",
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
            assert valid_signature?(wire)

            if wire.method == :DELETE do
              assert wire.headers["authorization"] == "GNAP test-sender-rotated-secret"
              {204, [], ""}
            else
              json(200, %{"access_token" => token(base, "test-sender-rotated-secret")})
            end

          "/tenant%2falpha/quotes" ->
            json(201, quote_data(base))

          "/tenant%2falpha/outgoing-payments" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-sender-rotated-secret"
            json(201, outgoing(base))
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
    assert {_, "", 0} = invoke(["payment", "quote", c.path, "--allow-http"])
    assert {_, "", 0} = invoke(args(c.path) ++ ["--yes"])
    before = File.read!(c.path)
    assert {_, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert {_, "", 0} = invoke(["payment", "prepare", c.path, "--allow-http"])
    assert {_, "", 0} = invoke(["payment", "quote", c.path, "--allow-http"])

    assert {stdout, "", 0} =
             invoke(
               ["payment", "authorize", c.path, "-", "--allow-http", "--json"],
               Jason.encode!(intent())
             )

    assert Jason.decode!(stdout)["status"] == "approved"
    assert File.read!(c.path) == before
    assert {_, "", 0} = invoke(["token", "revoke", c.path, "--allow-http"])
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, false)
    assert File.read!(c.path) == before
    assert {_, "", 0} = invoke(["grant", "cancel", c.path, "--allow-http"])
    assert load(c.path)["state"] == "cancelled"
    wires = drain()
    assert length(wires) == 11
    assert Enum.count(wires, &(&1.target == "/tenant%2falpha/outgoing-payments")) == 1
  end

  test "a failed creation response is saved once and never automatically retried", c do
    base =
      HTTPServer.start(fn wire -> json(201, Map.put(outgoing(origin(wire)), "failed", true)) end)

    write(c.path, quoted(base))
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--yes", "--json"])
    assert Jason.decode!(stdout)["failed"] == true
    assert Jason.decode!(stdout)["status"] == "created"
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout)["failed"] == true and Jason.decode!(stdout)["saved"] == false
    assert File.read!(c.path) == before
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "quote and receiver bindings are checked before any prompt or mutation", c do
    base = HTTPServer.start({500, [], "private-server-body"})

    for session <- [
          authorized(base),
          prepared(base),
          put_in(quoted(base), ["payment", "quote"], %{}),
          put_in(
            quoted(base),
            ["payment", "quote", "walletAddress"],
            "https://other.example/wallet"
          ),
          put_in(
            quoted(base),
            ["payment", "quote", "receiver"],
            "https://other.example/incoming-payments/id"
          ),
          put_in(quoted(base), ["payment", "incoming_payment"], %{}),
          put_in(quoted(base), ["payment", "receiver_grant", "key_id"], "other")
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", stderr, 2} = invoke(args(c.path), "send\n")
      refute stderr =~ "Type send"
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "pending, wait-only and revoked sender tokens cannot create an outgoing payment", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    wait_only = quoted(base) |> update_in(["response"], &Map.delete(&1, "access_token"))

    for session <- [
          Map.put(quoted(base), "kind", "grant-request") |> Map.put("response", pending(base)),
          wait_only,
          Map.put(wait_only, "kind", "token-revocation")
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "damaged cached results and existing attempt records never trigger replacement creation",
       c do
    base = HTTPServer.start({500, [], "private-server-body"})

    for session <- [
          put_in(quoted(base), ["payment", "outgoing_payment"], outgoing(base)),
          put_in(quoted(base), ["payment", "outgoing_request"], %{}),
          put_in(quoted(base), ["payment", "stage"], "outgoing-created"),
          quoted(base)
          |> put_in(["payment", "stage"], "outgoing-created")
          |> put_in(["payment", "outgoing_payment"], %{})
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "identity errors precede confirmation and matching flags override conflicting environment",
       c do
    base = HTTPServer.start(fn wire -> json(201, outgoing(origin(wire))) end)
    write(c.path, quoted(base))
    before = File.read!(c.path)

    for flags <- [
          ["--key-id", "other"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", "missing-private-key"]
        ] do
      assert {"", stderr, 2} = invoke(args(c.path) ++ flags, "send\n")
      refute stderr =~ "Type send"
      assert File.read!(c.path) == before
    end

    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    System.put_env("PRIVATE_KEY_FILE", "missing-private-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-source")

    assert {_, "", 0} =
             invoke(
               args(c.path) ++
                 [
                   "--yes",
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

  test "known SDK preflight failures restore the ready quote and remove the attempted request",
       c do
    for change <- [
          fn s ->
            put_in(
              s,
              ["payment", "sender_wallet", "resourceServer"],
              "https://user:private-password@payments.example/base"
            )
          end,
          fn s -> put_in(s, ["response", "access_token", "value"], "invalid token") end
        ] do
      session = change.(quoted("https://payments.example"))
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "ambiguous outgoing creation preserves the exact attempt and blocks every replay", c do
    for response <- [
          {302, [{"Location", "https://other.example/next"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {201, [], "not-json"},
          {201, [], "{}"},
          json(200, outgoing("https://payments.example")),
          json(201, put_in(outgoing("https://payments.example"), ["sentAmount", "value"], "151"))
        ] do
      base = HTTPServer.start(response)
      original = quoted(base)
      write(c.path, original)
      assert {"", stderr, 1} = invoke(args(c.path) ++ ["--yes"])
      assert stderr =~ "outgoing payment may have been created or started"
      saved = load(c.path)
      assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-finish"
      assert saved["response"] == original["response"]
      assert saved["payment"]["quote"] == original["payment"]["quote"]
      assert saved["payment"]["receiver_grant"] == original["payment"]["receiver_grant"]

      assert_enriched(saved["payment"]["outgoing_request"], %{
        "walletAddress" => base <> "/sender",
        "quoteId" => quote_data(base)["id"]
      })

      assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])

      for command <- [
            ["payment", "quote"],
            ["payment", "prepare"],
            ["grant", "continue"],
            ["grant", "cancel"],
            ["token", "rotate"],
            ["token", "revoke"]
          ] do
        assert {"", _, 2} = invoke(command ++ [c.path, "--allow-http"])
      end

      assert_received {:http_request,
                       %{method: :POST, target: "/tenant%2falpha/outgoing-payments"}}

      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "concurrent finish and token management share the durable lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, outgoing(origin(wire))))
      end)

    write(c.path, quoted(base))
    task = Task.async(fn -> PaymentFinish.run(c.path, allow_http: true, yes: true) end)
    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(args(c.path) ++ ["--yes"])
    assert {"", _, 1} = invoke(["token", "rotate", c.path, "--allow-http"])
    send(server, :release)
    assert {:ok, %{stage: "outgoing-created"}} = Task.await(task)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed finish retains its attempt and lock for reconciliation", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, outgoing(origin(wire))))
      end)

    write(c.path, quoted(base))

    {pid, monitor} =
      spawn_monitor(fn -> PaymentFinish.run(c.path, allow_http: true, yes: true) end)

    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert load(c.path)["state"] == "in-flight" and
             load(c.path)["attempt_operation"] == "payment-finish"

    assert load(c.path)["payment"]["outgoing_request"]
    assert {"", _, 1} = invoke(args(c.path) ++ ["--yes"])
    send(server, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "pre-request and post-response save failures cannot report a created payment", c do
    base = HTTPServer.start(fn wire -> json(201, outgoing(origin(wire))) end)
    path = Path.join(c.directory, String.duplicate("s", 240))
    write(path, quoted(base))
    before = File.read!(path)
    assert {"", _, 1} = invoke(args(path) ++ ["--yes"])
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
        json(201, outgoing(origin(wire)))
      end)

    write(path, quoted(base))
    assert {"", _, 1} = invoke(args(path) ++ ["--yes"])
    saved = load(Path.join(moved, "session.json"))
    assert saved["state"] == "in-flight" and saved["payment"]["outgoing_request"]
    refute Map.has_key?(saved["payment"], "outgoing_payment")
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "private-file rules and strict confirmation flag scope apply before payment creation", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, quoted(base))
    before = File.read!(c.path)
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])
    File.chmod!(c.path, 0o600)
    link = Path.join(c.directory, "link.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link) ++ ["--yes"])
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(c.path) ++ ["--yes"])
    File.rm!(link)
    File.write!(c.path <> ".lock", "interrupted")
    assert {"", _, 1} = invoke(args(c.path) ++ ["--yes"])
    assert File.read!(c.path <> ".lock") == "interrupted" and File.read!(c.path) == before

    for argv <- [
          ["payment", "finish"],
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

    for command <- [
          ["help"],
          ["version"],
          ["wallet", "get"],
          ["incoming", "create"],
          ["quote", "create"],
          ["outgoing", "create"],
          ["grant", "request"],
          ["token", "rotate"],
          ["payment", "start"],
          ["payment", "quote"]
        ] do
      assert {"", _, 2} = invoke(command ++ ["--yes"])
      assert {"", _, 2} = invoke(command ++ ["--no-yes"])
    end

    assert {stdout, "", 0} = invoke(["payment", "finish", "--help", "--yes"])
    assert stdout =~ "payment finish <session>" and stdout =~ "--yes"
    refute_receive {:http_request, _}, 20
  end

  defp args(path), do: ["payment", "finish", path, "--allow-http"]

  defp quoted(base),
    do:
      authorized(base)
      |> put_in(["payment", "stage"], "quote-ready")
      |> put_in(["payment", "quote"], quote_data(base))

  defp outgoing(base),
    do: %{
      "id" => base <> "/tenant%2falpha/outgoing-payments/id?opaque=a%2Bb",
      "walletAddress" => base <> "/sender",
      "receiver" => incoming(base)["id"],
      "quoteId" => quote_data(base)["id"],
      "debitAmount" => core(quote_data(base)["debitAmount"]),
      "receiveAmount" => quote_data(base)["receiveAmount"],
      "sentAmount" => %{"value" => "75", "assetCode" => "USD", "assetScale" => 2},
      "createdAt" => "2026-11-19T10:20:30.123456+02:00",
      "failed" => false,
      "grantSpentDebitAmount" => %{"value" => "180", "assetCode" => "USD", "assetScale" => 2},
      "metadata" => %{"sharedSecret" => "test-outgoing-secret"},
      "extension" => "private-server-body"
    }

  defp summary(path, base, saved?),
    do: %{
      "status" => "created",
      "stage" => "outgoing-created",
      "saved" => saved?,
      "session" => path,
      "outgoing_payment_url" => outgoing(base)["id"],
      "failed" => false,
      "debit_amount" => outgoing(base)["debitAmount"],
      "receive_amount" => outgoing(base)["receiveAmount"],
      "sent_amount" => outgoing(base)["sentAmount"]
    }

  defp core(amount), do: Map.take(amount, ~w(value assetCode assetScale))

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
    {stdout, stderr, status} =
      case System.get_env("OPEN_PAYMENTS_TEST_EXECUTABLE") do
        nil ->
          stderr =
            capture_io(:stderr, fn ->
              stdout =
                capture_io([input: input], fn -> send(self(), {:status, CLI.run(argv)}) end)

              send(self(), {:stdout, stdout})
            end)

          assert_received {:stdout, stdout}
          assert_received {:status, status}
          {stdout, stderr, status}

        executable ->
          OpenPaymentsSnippets.Test.Executable.run(executable, argv, input)
      end

    for secret <- [
          "test-continuation-secret",
          "test-issued-secret",
          "test-quote-secret",
          "test-outgoing-secret",
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
