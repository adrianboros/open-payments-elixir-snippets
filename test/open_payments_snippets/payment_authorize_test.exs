defmodule OpenPaymentsSnippets.PaymentAuthorizeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.PaymentAuthorization
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
        "open-payments-authorize-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  test "requests bounded sender permissions once and archives receiver credentials before HTTP",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        saved = load(path)
        assert saved["state"] == "in-flight" and saved["attempt_operation"] == "payment-authorize"
        assert saved["payment"]["stage"] == "sender-grant"
        refute Map.has_key?(saved, "response")

        assert saved["payment"]["receiver_grant"]["response"]["access_token"]["value"] ==
                 "test-issued-secret"

        assert saved["payment"]["receiver_grant"]["callback_verified"]
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(path <> ".lock").mode &&& 0o777) == 0o600
        assert wire.target == "/auth/sender?part=a%2Bb" and wire.method == :POST
        refute Map.has_key?(wire.headers, "authorization")
        assert valid_signature?(wire)
        request = Jason.decode!(wire.body)
        assert request["client"] == "https://client.example/signer"
        assert request["access_token"]["access"] == access(origin(wire))
        assert request["interact"]["finish"] == saved["finish"]
        assert byte_size(Base.url_decode64!(saved["finish"]["nonce"], padding: false)) == 32
        json(200, pending(origin(wire)))
      end)

    original = prepared(base)
    write(c.path, original)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-key")
    input = Path.join(c.directory, "authorization.json")
    File.write!(input, Jason.encode!(intent()))
    before = File.read!(input)
    assert {stdout, "", 0} = invoke(args(c.path, input) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, "pending", true)
    saved = load(c.path)
    assert saved["response"] == pending(base)
    assert saved["grant_endpoint"] == base <> "/auth/sender?part=a%2Bb"
    assert saved["kind"] == "grant-request" and saved["state"] == "ready"
    refute saved["callback_verified"]
    assert saved["payment"]["receiver_grant"] == Map.delete(original, "payment")

    assert Map.drop(saved["payment"], ~w(stage receiver_grant sender_authorization)) ==
             Map.drop(original["payment"], ["stage"])

    assert saved["payment"]["sender_authorization"] == intent()
    assert saved["finish"]["nonce"] != original["finish"]["nonce"]
    assert saved["finish"]["uri"] == intent()["finishUri"]
    refute Map.has_key?(saved, "token_rotation_response")
    refute Map.has_key?(saved, "token_rotated_at")
    refute Map.has_key?(saved, "attempted_at")
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    assert File.read!(input) == before
    assert File.read!(c.key) == @pem
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.directory), &String.contains?(&1, ".tmp-"))
    assert_received {:http_request, wire}
    refute valid_signature?(%{wire | body: wire.body <> " "})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute_receive {:http_request, _}, 20
  end

  test "immediate sender approval and repeated stdin authorization return the existing result",
       c do
    base = HTTPServer.start(fn wire -> json(200, approved(origin(wire))) end)
    write(c.path, prepared(base))
    assert {stdout, "", 0} = invoke(args(c.path), Jason.encode!(intent()))
    assert stdout =~ "Payment authorization approved\nStage  sender-grant"
    refute stdout =~ "Consent URL"
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"], Jason.encode!(intent()))
    assert Jason.decode!(stdout) == summary(c.path, base, "approved", false)
    assert File.read!(c.path) == before
    assert {_, "", 0} = invoke(["payment", "prepare", c.path, "--allow-http"])
    assert File.read!(c.path) == before
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "independent grants generate distinct nonces", c do
    base = HTTPServer.start(fn wire -> json(200, approved(origin(wire))) end)

    nonces =
      for index <- 1..2 do
        path = Path.join(c.directory, "session-#{index}.json")
        write(path, prepared(base))
        assert {_, "", 0} = invoke(args(path), Jason.encode!(intent()))
        assert_received {:http_request, %{method: :POST}}
        load(path)["finish"]["nonce"]
      end

    assert length(Enum.uniq(nonces)) == 2
    refute_receive {:http_request, _}, 20
  end

  test "start, prepare, sender consent, rotation, cached calls and cancellation compose", c do
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
            assert wire.headers["authorization"] == "GNAP test-issued-secret"
            json(201, incoming(base))

          "/auth/sender?part=a%2Bb" ->
            assert valid_signature?(wire)
            refute Map.has_key?(wire.headers, "authorization")
            assert Jason.decode!(wire.body)["access_token"]["access"] == access(base)
            json(200, pending(base))

          "/continue/sender?part=a%2Bb" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-sender-cont-secret"
            if wire.method == :DELETE, do: {204, [], ""}, else: json(200, approved(base))

          "/manage/sender?part=a%2Bb" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-sender-issued-secret"
            json(200, %{"access_token" => token(base, "test-sender-rotated-secret")})
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
    receiver = load(c.path)
    assert {_, "", 0} = invoke(args(c.path), Jason.encode!(intent()))
    sender = load(c.path)
    assert sender["payment"]["receiver_grant"] == Map.delete(receiver, "payment")
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"], Jason.encode!(intent()))
    assert Jason.decode!(stdout)["saved"] == false
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

    returned =
      sender["finish"]["uri"] <>
        "&" <> URI.encode_query(%{"hash" => hash, "interact_ref" => reference})

    File.write!(callback, String.replace(returned, "state=sender", "state=wrong"))
    before = File.read!(c.path)

    assert {"", _, 2} =
             invoke(["grant", "continue", c.path, "--callback-file", callback, "--allow-http"])

    assert File.read!(c.path) == before
    File.write!(callback, returned)

    assert {_, "", 0} =
             invoke(["grant", "continue", c.path, "--callback-file", callback, "--allow-http"])

    assert load(c.path)["callback_verified"]
    assert {_, "", 0} = invoke(["token", "rotate", c.path, "--allow-http"])
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"], Jason.encode!(intent()))
    assert Jason.decode!(stdout) == summary(c.path, base, "approved", false)
    assert {_, "", 0} = invoke(["payment", "prepare", c.path, "--allow-http"])
    assert File.read!(c.path) == before
    assert load(c.path)["payment"]["receiver_grant"] == Map.delete(receiver, "payment")
    assert load(c.path)["response"]["access_token"]["value"] == "test-sender-rotated-secret"
    assert {_, "", 0} = invoke(["grant", "cancel", c.path, "--allow-http"])
    assert load(c.path)["state"] == "cancelled"
    refute Map.has_key?(load(c.path), "payment")
    requests = drain()
    assert length(requests) == 8
    assert Enum.count(requests, &(&1.target == "/auth/sender?part=a%2Bb")) == 1
    assert Enum.count(requests, &(&1.target == "/tenant%2falpha/incoming-payments")) == 1
    refute Enum.any?(requests, &String.contains?(&1.target, "outgoing-payments"))
  end

  test "changed authorization input cannot initiate another grant", c do
    base = HTTPServer.start(fn wire -> json(200, pending(origin(wire))) end)
    write(c.path, prepared(base))
    assert {_, "", 0} = invoke(args(c.path), Jason.encode!(intent()))
    before = File.read!(c.path)

    for data <- [
          put_in(intent(), ["debitAmount", "value"], "300"),
          Map.put(intent(), "finishUri", "https://client.example/other")
        ] do
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(data))
      assert File.read!(c.path) == before
    end

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "invalid input fails without changing the prepared session or using HTTP", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, prepared(base))
    before = File.read!(c.path)

    for data <- [
          nil,
          [],
          %{},
          Map.delete(intent(), "finishUri"),
          Map.delete(intent(), "debitAmount"),
          Map.put(intent(), "unexpected", true),
          Map.put(intent(), "debitAmount", nil),
          put_in(intent(), ["debitAmount", "value"], 1.5),
          put_in(intent(), ["debitAmount", "value"], "18446744073709551616"),
          Map.put(intent(), "finishUri", "not-uri")
        ] do
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(data))
      assert File.read!(c.path) == before
    end

    for input <- ["not-json", <<255>>] do
      assert {"", _, 2} = invoke(args(c.path), input)
    end

    assert {"", _, 2} = invoke(args(c.path, Path.join(c.directory, "absent.json")))
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  test "unprepared, invalid or inconsistent payment contexts cannot authorize", c do
    base = HTTPServer.start({500, [], "private-server-body"})

    for session <- [
          Map.delete(prepared(base), "payment"),
          put_in(prepared(base), ["payment", "stage"], "receiver-grant")
          |> update_in(["payment"], &Map.delete(&1, "incoming_payment")),
          put_in(prepared(base), ["payment", "incoming_payment"], %{}),
          put_in(prepared(base), ["payment", "sender_wallet"], %{}),
          put_in(
            prepared(base),
            ["payment", "incoming_request", "walletAddress"],
            "https://other.example/wallet"
          ),
          Map.put(prepared(base), "grant_endpoint", "https://other.example/auth")
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "recorded signing identity wins over env and explicit mismatches fail", c do
    base = HTTPServer.start(fn wire -> json(200, approved(origin(wire))) end)
    write(c.path, prepared(base))
    before = File.read!(c.path)

    for flags <- [
          ["--key-id", "other"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", "missing-private-file"]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ flags, Jason.encode!(intent()))
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
                 ],
               Jason.encode!(intent())
             )

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "SDK preflight errors restore the original prepared receiver context", c do
    for change <- [
          fn s ->
            put_in(
              s,
              ["payment", "sender_wallet", "authServer"],
              "https://user:private-password@auth.example/sender"
            )
          end,
          fn s -> put_in(s, ["payment", "incoming_payment", "id"], "urn:unsupported:incoming") end
        ] do
      session = change.(prepared("https://payments.example"))
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "ambiguous sender outcomes preserve receiver credentials and block all replay", c do
    for response <- [
          {302, [{"Location", "https://other.example/next"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {200, [], "not-json"},
          {200, [], "{}"}
        ] do
      base = HTTPServer.start(response)
      original = prepared(base)
      write(c.path, original)
      assert {"", _, 1} = invoke(args(c.path), Jason.encode!(intent()))
      saved = load(c.path)
      assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-authorize"
      assert saved["payment"]["receiver_grant"] == Map.delete(original, "payment")
      refute Map.has_key?(saved, "response")
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))

      for command <- [
            ["payment", "prepare"],
            ["grant", "continue"],
            ["grant", "cancel"],
            ["token", "rotate"],
            ["token", "revoke"]
          ] do
        assert {"", _, 2} = invoke(command ++ [c.path, "--allow-http"])
      end

      assert_received {:http_request, %{method: :POST, target: "/auth/sender?part=a%2Bb"}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "damaged sender archive and endpoint bindings cannot be used by authorize or prepare", c do
    base = HTTPServer.start(fn wire -> json(200, approved(origin(wire))) end)
    write(c.path, prepared(base))
    assert {_, "", 0} = invoke(args(c.path), Jason.encode!(intent()))
    saved = load(c.path)
    assert_received {:http_request, %{method: :POST}}

    for session <- [
          update_in(saved, ["payment"], &Map.delete(&1, "receiver_grant")),
          put_in(saved, ["payment", "receiver_grant", "state"], "uncertain"),
          put_in(saved, ["payment", "receiver_grant", "key_id"], "other"),
          put_in(
            saved,
            ["payment", "receiver_grant", "grant_endpoint"],
            "https://other.example/auth"
          ),
          Map.put(saved, "grant_endpoint", "https://other.example/auth")
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))
      assert {"", _, 2} = invoke(["payment", "prepare", c.path, "--allow-http"])
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "revoked sender tokens report revoked without requesting another grant", c do
    base =
      HTTPServer.start(fn wire ->
        if wire.method == :DELETE, do: {204, [], ""}, else: json(200, approved(origin(wire)))
      end)

    write(c.path, prepared(base))
    assert {_, "", 0} = invoke(args(c.path), Jason.encode!(intent()))
    receiver = load(c.path)["payment"]["receiver_grant"]
    assert {_, "", 0} = invoke(["token", "revoke", c.path, "--allow-http"])
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"], Jason.encode!(intent()))
    assert Jason.decode!(stdout) == summary(c.path, base, "revoked", false)
    assert load(c.path)["payment"]["receiver_grant"] == receiver
    assert File.read!(c.path) == before
    assert_received {:http_request, %{method: :POST}}
    assert_received {:http_request, %{method: :DELETE, target: "/manage/sender?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
  end

  test "concurrent sender authorization and token operations share the session lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(200, pending(origin(wire))))
      end)

    write(c.path, prepared(base))
    input = Path.join(c.directory, "intent.json")
    File.write!(input, Jason.encode!(intent()))
    task = Task.async(fn -> PaymentAuthorization.run(c.path, input, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(args(c.path), Jason.encode!(intent()))
    assert {"", _, 1} = invoke(["token", "rotate", c.path, "--allow-http"])
    send(server, :release)
    assert {:ok, %{stage: "sender-grant"}} = Task.await(task)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed sender request retains the in-flight archive and stale lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(200, pending(origin(wire))))
      end)

    write(c.path, prepared(base))
    input = Path.join(c.directory, "intent.json")
    File.write!(input, Jason.encode!(intent()))

    {pid, monitor} =
      spawn_monitor(fn -> PaymentAuthorization.run(c.path, input, allow_http: true) end)

    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(c.path)["state"] == "in-flight"

    assert load(c.path)["payment"]["receiver_grant"]["response"]["access_token"]["value"] ==
             "test-issued-secret"

    assert {"", _, 1} = invoke(args(c.path), Jason.encode!(intent()))
    send(server, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "pre-request and post-response save failures never report authorization success", c do
    base = HTTPServer.start(fn wire -> json(200, approved(origin(wire))) end)
    path = Path.join(c.directory, String.duplicate("s", 240))
    write(path, prepared(base))
    before = File.read!(path)
    assert {"", _, 1} = invoke(args(path), Jason.encode!(intent()))
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
        json(200, approved(origin(wire)))
      end)

    write(path, prepared(base))
    assert {"", _, 1} = invoke(args(path), Jason.encode!(intent()))
    saved = load(Path.join(moved, "session.json"))
    assert saved["state"] == "in-flight" and saved["payment"]["receiver_grant"]
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "private-file rules, locks and unrelated flags fail before authorization", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, prepared(base))
    before = File.read!(c.path)
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))
    File.chmod!(c.path, 0o600)
    link = Path.join(c.directory, "link.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link), Jason.encode!(intent()))
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(c.path), Jason.encode!(intent()))
    File.rm!(link)
    File.write!(c.path <> ".lock", "interrupted")
    assert {"", _, 1} = invoke(args(c.path), Jason.encode!(intent()))
    assert File.read!(c.path <> ".lock") == "interrupted"
    assert File.read!(c.path) == before

    for argv <- [
          ["payment", "authorize"],
          ["payment", "authorize", c.path],
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

    assert {stdout, "", 0} = invoke(["payment", "authorize", "--help"])
    assert stdout =~ "payment authorize <session> <file|->"
    refute_receive {:http_request, _}, 20
  end

  defp args(path, source \\ "-"), do: ["payment", "authorize", path, source, "--allow-http"]

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

  defp summary(path, base, status, saved?) do
    result = %{
      "status" => status,
      "stage" => "sender-grant",
      "saved" => saved?,
      "session" => path
    }

    if status == "pending",
      do: Map.put(result, "consent_url", base <> "/consent/sender"),
      else: result
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
