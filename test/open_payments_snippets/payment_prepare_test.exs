defmodule OpenPaymentsSnippets.PaymentPrepareTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.PaymentPreparation
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
        "open-payments-prepare-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  test "creates exactly once using saved identity, token, canonical intent and resource server",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        assert load(path)["state"] == "in-flight"
        assert load(path)["attempt_operation"] == "payment-prepare"
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(path <> ".lock").mode &&& 0o777) == 0o600
        assert wire.target == "/tenant%2falpha/incoming-payments"
        assert wire.headers["authorization"] == "GNAP test-issued-secret"
        assert valid_signature?(wire)
        json(201, incoming(origin(wire)))
      end)

    session = initial(base)
    write(c.path, session)
    original_key = File.read!(c.key)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, true)
    assert_received {:http_request, %{method: :POST} = wire}
    assert Jason.decode!(wire.body) == session["payment"]["incoming_request"]
    assert wire.headers["content-length"] == Integer.to_string(byte_size(wire.body))
    refute valid_signature?(%{wire | body: wire.body <> " "})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed"))
    saved = load(c.path)
    assert saved["state"] == "ready" and saved["payment"]["stage"] == "incoming-ready"
    assert saved["payment"]["incoming_payment"] == incoming(base)
    assert {:ok, _, _} = DateTime.from_iso8601(saved["payment"]["incoming_created_at"])
    assert Map.drop(saved, ["payment"]) == Map.drop(session, ["payment"])

    assert Map.drop(saved["payment"], ~w(stage incoming_payment incoming_created_at)) ==
             Map.drop(session["payment"], ["stage"])

    assert File.read!(c.path) =~ "test-ilp-secret"
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == summary(c.path, base, false)
    assert File.read!(c.path) == before
    assert File.read!(c.key) == original_key
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.directory), &String.contains?(&1, ".tmp-"))
    refute_receive {:http_request, _}, 20
  end

  test "start, verified continuation, token rotation, preparation, repeated preparation and cancellation compose",
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
            assert valid_signature?(wire)
            json(200, pending(base))

          "/continue/receiver?part=a%2Bb" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-continuation-secret"

            if wire.method == :DELETE,
              do: {204, [], ""},
              else: json(200, initial(base)["response"])

          "/manage/receiver?part=a%2Bb" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-issued-secret"
            json(200, %{"access_token" => token(base, "test-rotated-secret")})

          "/tenant%2falpha/incoming-payments" ->
            assert valid_signature?(wire)
            assert wire.headers["authorization"] == "GNAP test-rotated-secret"
            json(201, incoming(base))
        end
      end)

    System.put_env("WALLET_ADDRESS", base <> "/sender")

    intent = %{
      "receiver" => base <> "/receiver",
      "receiveAmount" => amount(),
      "finishUri" => "https://client.example/return?state=flow",
      "metadata" => %{"memo" => "Café 🌍"}
    }

    assert {_, "", 0} =
             invoke(
               ["payment", "start", "-", "--output", c.path, "--allow-http"],
               Jason.encode!(intent)
             )

    before = File.read!(c.path)
    assert {"", _, 2} = invoke(args(c.path))
    assert File.read!(c.path) == before
    saved = load(c.path)
    reference = "test-private-reference"

    hash =
      :crypto.hash(
        :sha256,
        Enum.join(
          [saved["finish"]["nonce"], "test-server-nonce", reference, saved["grant_endpoint"]],
          "\n"
        )
      )
      |> Base.encode64()

    callback = Path.join(c.directory, "callback.txt")

    File.write!(
      callback,
      saved["finish"]["uri"] <>
        "&" <> URI.encode_query(%{"hash" => hash, "interact_ref" => reference})
    )

    assert {_, "", 0} =
             invoke(["grant", "continue", c.path, "--callback-file", callback, "--allow-http"])

    assert load(c.path)["callback_verified"]
    assert {_, "", 0} = invoke(["token", "rotate", c.path, "--allow-http"])
    assert {_, "", 0} = invoke(args(c.path))
    prepared = load(c.path)
    assert prepared["kind"] == "grant-continuation"
    assert prepared["token_rotation_response"]["access_token"]["value"] == "test-rotated-secret"
    assert {_, "", 0} = invoke(args(c.path))
    assert load(c.path) == prepared
    assert {_, "", 0} = invoke(["grant", "cancel", c.path, "--allow-http"])
    assert load(c.path)["state"] == "cancelled"
    refute Map.has_key?(load(c.path), "payment")
    wires = drain()
    assert length(wires) == 7
    assert Enum.count(wires, &(&1.target == "/tenant%2falpha/incoming-payments")) == 1
    assert Enum.all?(wires, &(&1.method in [:GET, :POST, :DELETE]))
  end

  test "text output reports only the saved URL and ready state", c do
    base = HTTPServer.start(fn wire -> json(201, incoming(origin(wire))) end)
    write(c.path, initial(base))
    assert {stdout, "", 0} = invoke(args(c.path))

    assert stdout ==
             "Incoming payment ready\nStage  incoming-ready\nSession  #{Jason.encode!(c.path)}\nIncoming payment  #{Jason.encode!(incoming(base)["id"])}\n"

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "pending, wait-only and revoked grants cannot consume continuation credentials as resource tokens",
       c do
    base = HTTPServer.start({500, [], "private-server-body"})

    wait_only =
      initial(base)
      |> Map.put("kind", "grant-continuation")
      |> update_in(["response"], &Map.delete(&1, "access_token"))

    revoked = Map.put(wait_only, "kind", "token-revocation")

    for session <- [Map.put(initial(base), "response", pending(base)), wait_only, revoked] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", stderr, 2} = invoke(args(c.path))
      assert stderr =~ "No issued receiver token"
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "invalid and mismatched payment context is rejected before HTTP or file mutation", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    valid = initial(base)

    for session <- [
          Map.delete(valid, "payment"),
          Map.put(valid, "payment", nil),
          put_in(valid, ["payment", "version"], 2),
          put_in(valid, ["payment", "stage"], "future"),
          put_in(valid, ["payment", "sender_wallet"], %{}),
          put_in(valid, ["payment", "receiver_wallet"], []),
          put_in(valid, ["payment", "incoming_request", "incomingAmount"], nil),
          update_in(valid, ["payment", "incoming_request"], &Map.delete(&1, "incomingAmount")),
          put_in(
            valid,
            ["payment", "incoming_request", "walletAddress"],
            "https://other.example/wallet"
          ),
          Map.put(valid, "grant_endpoint", "https://other.example/auth"),
          put_in(valid, ["payment", "incoming_payment"], incoming(base))
        ] do
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "a damaged cached result never triggers a replacement creation", c do
    base = HTTPServer.start({500, [], "private-server-body"})

    for data <- [nil, %{}, Map.put(incoming(base), "methods", nil)] do
      session =
        initial(base)
        |> put_in(["payment", "stage"], "incoming-ready")
        |> put_in(["payment", "incoming_payment"], data)

      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "identity mismatch and unavailable keys leave authorization unchanged", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, initial(base))
    before = File.read!(c.path)

    for flags <- [
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-id", "other"],
          ["--key-file", "missing-private-file"]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ flags)
      assert File.read!(c.path) == before
    end

    session = put_in(initial(base), ["signing_jwk", "x"], "different-public-key")
    write(c.path, session)
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "matching explicit identity and key override conflicting environment values", c do
    base = HTTPServer.start(fn wire -> json(201, incoming(origin(wire))) end)
    write(c.path, initial(base))
    System.put_env("PRIVATE_KEY_FILE", "missing-private-file")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-private-source")

    assert {_, "", 0} =
             invoke(
               args(c.path) ++
                 [
                   "--wallet-address",
                   "https://client.example/signer",
                   "--key-id",
                   "test-key",
                   "--key-file",
                   c.key
                 ]
             )

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "known SDK preflight errors restore the original ready session without HTTP", c do
    for change <- [
          fn s ->
            put_in(
              s,
              ["payment", "receiver_wallet", "resourceServer"],
              "https://user:private-password@payments.example/base"
            )
          end,
          fn s -> put_in(s, ["response", "access_token", "value"], "invalid token") end
        ] do
      session = change.(initial("https://payments.example"))
      write(c.path, session)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "HTTP redirects, errors, drops and invalid success responses retain uncertain state and block replay",
       c do
    for response <- [
          {302, [{"Location", "https://other.example/next"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {201, [], "not-json"},
          {201, [], "{}"},
          {200, [], Jason.encode!(incoming("https://payments.example"))},
          json(
            201,
            put_in(incoming("https://payments.example"), ["receivedAmount", "assetCode"], "USD")
          )
        ] do
      base = HTTPServer.start(response)
      session = initial(base)
      write(c.path, session)
      assert {"", _, 1} = invoke(args(c.path))
      saved = load(c.path)
      assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-prepare"
      assert saved["response"] == session["response"]
      assert saved["payment"] == session["payment"]
      assert {"", _, 2} = invoke(args(c.path))

      for command <- [
            ["grant", "continue"],
            ["grant", "cancel"],
            ["token", "rotate"],
            ["token", "revoke"]
          ] do
        assert {"", _, 2} = invoke(command ++ [c.path, "--allow-http"])
      end

      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "non-private, symlink, hard-linked, malformed, unavailable and locked sessions are rejected",
       c do
    base = HTTPServer.start({500, [], "private-server-body"})
    write(c.path, initial(base))
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
    assert File.read!(c.path) == before
    File.write!(c.path, "not-json")
    assert {"", _, 2} = invoke(args(c.path))
    File.rm!(c.path)
    assert {"", _, 2} = invoke(args(c.path))
    write(c.path, initial(base))
    before = File.read!(c.path)
    File.write!(c.path <> ".lock", "interrupted")
    assert {"", _, 1} = invoke(args(c.path))
    assert File.read!(c.path <> ".lock") == "interrupted"
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  test "concurrent preparation and token management share the private session lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, incoming(origin(wire))))
      end)

    write(c.path, initial(base))
    task = Task.async(fn -> PaymentPreparation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(args(c.path))
    assert {"", _, 1} = invoke(["token", "rotate", c.path, "--allow-http"])
    send(server, :release)
    assert {:ok, %{stage: "incoming-ready"}} = Task.await(task)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "killed preparation retains its in-flight marker and lock", c do
    owner = self()

    base =
      HTTPServer.start(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(201, incoming(origin(wire))))
      end)

    write(c.path, initial(base))
    {pid, monitor} = spawn_monitor(fn -> PaymentPreparation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(c.path)["state"] == "in-flight"
    assert load(c.path)["attempt_operation"] == "payment-prepare"
    assert {"", _, 1} = invoke(args(c.path))
    send(server, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "failed pre-request persistence sends no HTTP and preserves the ready session", c do
    base = HTTPServer.start({500, [], "private-server-body"})
    path = Path.join(c.directory, String.duplicate("s", 240))
    write(path, initial(base))
    before = File.read!(path)
    assert {"", _, 1} = invoke(args(path))
    assert File.read!(path) == before
    refute File.exists?(path <> ".lock")
    refute_receive {:http_request, _}, 20
  end

  test "post-response save failure retains the recorded attempt and reports failure", c do
    parent = Path.join(c.directory, "private")
    moved = Path.join(c.directory, "moved")
    File.mkdir!(parent)
    path = Path.join(parent, "session.json")

    base =
      HTTPServer.start(fn wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        json(201, incoming(origin(wire)))
      end)

    write(path, initial(base))
    assert {"", stderr, 1} = invoke(args(path))
    assert stderr =~ "Unable to save private grant session"
    assert load(Path.join(moved, "session.json"))["state"] == "in-flight"
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "missing paths and unrelated options fail before initialization while help is available" do
    for argv <- [
          ["payment", "prepare"],
          ["payment", "prepare", ""],
          args("private-session") ++ ["extra"],
          args("private-session") ++ ["--access-token-file", "private-token"],
          args("private-session") ++ ["--output", "private-output"],
          args("private-session") ++ ["--callback-file", "private-callback"],
          args("private-session") ++ ["--hash-encoding", "base64"],
          args("private-session") ++ ["--first", "1"],
          args("private-session") ++ ["--jwks"],
          args("private-session") ++ ["--version"]
        ] do
      assert {"", _, 2} = invoke(argv)
    end

    assert {stdout, "", 0} = invoke(["payment", "prepare", "--help"])
    assert stdout =~ "payment prepare <session>"
    refute_received {:http_request, _}
  end

  defp args(path), do: ["payment", "prepare", path, "--allow-http"]
  defp amount, do: %{"value" => "100", "assetCode" => "EUR", "assetScale" => 2}
  defp origin(wire), do: "http://" <> wire.headers["host"]

  defp json(status, data),
    do: {status, [{"Content-Type", "application/json"}], Jason.encode!(data)}

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp write(path, session) do
    File.write!(path, Jason.encode!(session, pretty: true) <> "\n")
    File.chmod!(path, 0o600)
  end

  defp summary(path, base, saved?),
    do: %{
      "status" => "ready",
      "stage" => "incoming-ready",
      "saved" => saved?,
      "session" => path,
      "incoming_payment_url" => incoming(base)["id"]
    }

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
      "manage" => base <> "/manage/receiver?part=a%2Bb",
      "access" => [
        %{
          "type" => "incoming-payment",
          "actions" => ["create", "read"],
          "identifier" => base <> "/receiver"
        }
      ]
    }

  defp pending(base),
    do: %{
      "continue" => Map.put(initial(base)["response"]["continue"], "wait", 0),
      "interact" => %{"redirect" => base <> "/consent", "finish" => "test-server-nonce"}
    }

  defp initial(base) do
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
      "callback_verified" => false,
      "finish" => %{
        "method" => "redirect",
        "uri" => "https://client.example/return?state=flow",
        "nonce" => "test-client-nonce"
      },
      "response" => %{
        "continue" => %{
          "uri" => base <> "/continue/receiver?part=a%2Bb",
          "access_token" => %{"value" => "test-continuation-secret"},
          "wait" => 3600
        },
        "access_token" => token(base, "test-issued-secret"),
        "extension" => "private-server-body"
      },
      "payment" => %{
        "version" => 1,
        "stage" => "receiver-grant",
        "incoming_request" => %{
          "walletAddress" => base <> "/receiver",
          "incomingAmount" => amount(),
          "metadata" => %{"memo" => "Café 🌍"}
        },
        "sender_wallet" => wallet(base, "sender"),
        "receiver_wallet" => wallet(base, "receiver")
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
