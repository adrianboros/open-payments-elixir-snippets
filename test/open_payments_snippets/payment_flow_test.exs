defmodule OpenPaymentsSnippets.PaymentFlowTest do
  use ExUnit.Case, async: false

  @moduletag :consumer_flow

  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.HTTPServer

  # Public RFC 8032 vector 1; no operational key or provider is used.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @public Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)
  @debit %{"value" => "2600", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @created "2026-11-19T10:20:30.123456+02:00"
  @client_nonce "flow-client-nonce"
  @server_nonce "flow-server-nonce"
  @reference "flow-interaction-ref"
  @callback_uri "https://client.example/return?state=session-17"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "open-payments-cli-flow-#{System.unique_integer([:positive])}")

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    names = ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 PRIVATE_KEY ACCESS_TOKEN)
    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    key = Path.join(dir, "rfc8032.pem")
    File.write!(key, @pem)
    System.put_env("KEY_ID", "flow-key")
    System.put_env("PRIVATE_KEY_FILE", key)
    # Resource operations below must use their explicit token files instead.
    System.put_env("ACCESS_TOKEN", "wrong-environment-token")
    %{dir: dir, key: key}
  end

  for form <- [:quote, :direct] do
    test "completes the #{form} CLI payment flow with private grants, rotated tokens and cleanup",
         c do
      base =
        HTTPServer.start(fn wire ->
          verify_wire(wire)
          route(wire)
        end)

      sender = base <> "/wallets/sender"
      receiver = base <> "/wallets/receiver"
      System.put_env("WALLET_ADDRESS", sender)
      assert run(["wallet", "get", sender])["assetCode"] == "USD"
      assert run(["wallet", "get", receiver])["assetCode"] == "EUR"

      assert [%{"kid" => "flow-key"}] =
               run(["wallet", "keys", sender])["keys"] |> Enum.map(&Map.take(&1, ["kid"]))

      receiver_session = Path.join(c.dir, "receiver.json")

      assert run(
               [
                 "grant",
                 "request",
                 "-",
                 "--wallet-address",
                 receiver,
                 "--output",
                 receiver_session
               ],
               grant(receiver, "receiver")
             )["status"] == "approved"

      receiver_token = export_token(receiver_session, Path.join(c.dir, "receiver-token.txt"))

      incoming =
        run(["incoming", "create", "-", "--access-token-file", receiver_token], %{
          "walletAddress" => receiver,
          "incomingAmount" => @receive
        })

      incoming_id = incoming["id"]
      assert incoming["methods"] |> hd() |> Map.fetch!("sharedSecret") == "[REDACTED]"
      assert run(["incoming", "get-public", incoming_id])["receivedAmount"]["value"] == "0"

      assert run(["incoming", "get", incoming_id, "--access-token-file", receiver_token]) ==
               incoming

      sender_session = Path.join(c.dir, "sender.json")

      assert run(["grant", "request", "-", "--output", sender_session], grant(sender, "sender"))[
               "status"
             ] == "pending"

      record = load(sender_session)
      assert record["response"]["interact"]["redirect"] == base <> "/consent/sender"
      assert record["grant_endpoint"] == base <> "/auth/sender?tenant=a%2Bb"
      before_callback = drain()
      callback = Path.join(c.dir, "callback.txt")

      hash =
        :crypto.hash(
          :sha256,
          Enum.join([@client_nonce, @server_nonce, @reference, record["grant_endpoint"]], "\n")
        )
        |> Base.encode64()

      returned =
        @callback_uri <> "&" <> URI.encode_query(%{"hash" => hash, "interact_ref" => @reference})

      File.write!(callback, String.replace(returned, "state=session-17", "state=wrong"))
      original = File.read!(sender_session)

      assert {"", stderr} =
               invoke(["grant", "continue", sender_session, "--callback-file", callback], nil, 2)

      assert stderr =~ "Callback query parameters do not match this session"
      assert File.read!(sender_session) == original
      assert drain() == []
      File.write!(callback, returned <> "\n")

      assert run(["grant", "continue", sender_session, "--callback-file", callback])["status"] ==
               "approved"

      assert load(sender_session)["callback_verified"]
      sender_token = export_token(sender_session, Path.join(c.dir, "sender-token.txt"))

      quoted =
        run(["quote", "create", "-", "--access-token-file", sender_token], %{
          "walletAddress" => sender,
          "receiver" => incoming_id,
          "method" => "ilp"
        })

      assert quoted["debitAmount"] == @debit and quoted["receiveAmount"] == @receive
      assert run(["quote", "get", quoted["id"], "--access-token-file", sender_token]) == quoted
      assert run(["token", "rotate", sender_session])["status"] == "rotated"
      # An old exported copy remains stale until the caller explicitly updates it.
      assert File.read!(sender_token) == "flow-sender-resource-1\n"
      sender_token = export_token(sender_session, sender_token)

      assert load(sender_session)["response"]["continue"]["access_token"]["value"] ==
               "flow-sender-cont-2"

      request = %{
        "walletAddress" => sender,
        "metadata" => %{"reference" => "invoice-17", "memo" => "Café 🌍"}
      }

      request =
        case unquote(form) do
          :quote ->
            Map.put(request, "quoteId", quoted["id"])

          :direct ->
            Map.merge(request, %{"incomingPayment" => incoming_id, "debitAmount" => @debit})
        end

      created = run(["outgoing", "create", "-", "--access-token-file", sender_token], request)
      assert created["grantSpentDebitAmount"] == @debit
      fetched = run(["outgoing", "get", created["id"], "--access-token-file", sender_token])
      assert fetched == Map.drop(created, ~w(grantSpentDebitAmount grantSpentReceiveAmount))
      assert fetched["sentAmount"] == @debit and fetched["metadata"] == request["metadata"]

      assert [^fetched] =
               run([
                 "outgoing",
                 "list",
                 sender,
                 "--first",
                 "1",
                 "--access-token-file",
                 sender_token
               ])["result"]

      assert run(["outgoing", "grant-spent-amounts", sender, "--access-token-file", sender_token]) ==
               %{"spentDebitAmount" => @debit, "spentReceiveAmount" => @receive}

      completed =
        run(["incoming", "complete", incoming_id, "--access-token-file", receiver_token])

      assert completed["completed"] and completed["receivedAmount"] == @receive

      assert [^completed] =
               run(["incoming", "list", receiver, "--access-token-file", receiver_token])[
                 "result"
               ]

      assert run(["token", "revoke", sender_session])["status"] == "revoked"
      refute File.read!(sender_session) =~ "flow-sender-resource-2"
      assert run(["grant", "cancel", sender_session])["status"] == "cancelled"
      assert run(["grant", "cancel", receiver_session])["status"] == "cancelled"

      requests = before_callback ++ drain()
      assert length(requests) == 29

      assert Enum.count(
               requests,
               &(&1.method == :POST and &1.target == "/tenant/sender/outgoing-payments")
             ) == 1

      assert Enum.count(
               requests,
               &(&1.method == :POST and &1.target == "/continue/sender/1?part=a%2Bb")
             ) == 1

      refute Enum.any?(requests, &String.starts_with?(&1.target, "/consent"))

      for path <- [sender_session, receiver_session] do
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert load(path)["state"] == "cancelled"
        refute File.read!(path) =~ "resource-"
        refute File.read!(path) =~ "cont-"
        refute File.exists?(path <> ".lock")
      end

      assert File.read!(c.key) == @pem
      refute_receive {:http_request, _}, 20
    end
  end

  defp grant(wallet, role) do
    access =
      if role == "receiver",
        do: [
          %{
            "type" => "incoming-payment",
            "actions" => ["create", "read", "complete", "list"],
            "identifier" => wallet
          }
        ],
        else: [
          %{"type" => "quote", "actions" => ["create", "read"]},
          %{
            "type" => "outgoing-payment",
            "actions" => ["create", "read", "list"],
            "identifier" => wallet
          }
        ]

    data = %{"client" => wallet, "access_token" => %{"access" => access}}

    if role == "receiver",
      do: data,
      else:
        Map.put(data, "interact", %{
          "start" => ["redirect"],
          "finish" => %{"method" => "redirect", "uri" => @callback_uri, "nonce" => @client_nonce}
        })
  end

  defp route(wire) do
    base = "http://" <> wire.headers["host"]
    path = wire.target |> String.split("?", parts: 2) |> hd()
    payload = if wire.body == "", do: nil, else: Jason.decode!(wire.body)

    case {wire.method, path} do
      {:GET, "/wallets/sender/jwks.json"} ->
        json(200, %{
          "keys" => [
            %{
              "kid" => "flow-key",
              "kty" => "OKP",
              "crv" => "Ed25519",
              "alg" => "EdDSA",
              "x" => Base.url_encode64(@public, padding: false)
            }
          ]
        })

      {:GET, "/wallets/" <> role} when role in ["sender", "receiver"] ->
        json(200, %{
          "id" => base <> path,
          "assetCode" => if(role == "sender", do: "USD", else: "EUR"),
          "assetScale" => 2,
          "authServer" => base <> "/auth/" <> role <> "?tenant=a%2Bb",
          "resourceServer" => base <> "/tenant/" <> role
        })

      {:POST, "/auth/" <> role} when role in ["sender", "receiver"] ->
        assert wire.target == path <> "?tenant=a%2Bb"
        assert payload == grant(base <> "/wallets/" <> role, role)
        Process.put({:access, role}, payload["access_token"]["access"])

        if role == "receiver" do
          json(200, %{
            "continue" => continuation(base, role, 1),
            "access_token" => token(base, role, 1)
          })
        else
          json(200, %{
            "continue" => continuation(base, role, 1),
            "interact" => %{"redirect" => base <> "/consent/sender", "finish" => @server_nonce}
          })
        end

      {:POST, "/continue/sender/1"} ->
        authorize(wire, "flow-sender-cont-1")
        assert payload == %{"interact_ref" => @reference}
        Process.put(:sender_token, "flow-sender-resource-1")

        json(200, %{
          "continue" => continuation(base, "sender", 2),
          "access_token" => token(base, "sender", 1)
        })

      {:POST, "/manage/sender/1"} ->
        authorize(wire, "flow-sender-resource-1")
        assert wire.body == ""
        Process.put(:sender_token, "flow-sender-resource-2")
        json(200, %{"access_token" => token(base, "sender", 2)})

      {:DELETE, "/manage/sender/2"} ->
        authorize(wire, "flow-sender-resource-2")
        Process.put(:sender_token, nil)
        {204, [], ""}

      {:DELETE, "/continue/" <> suffix} ->
        [role, version] = String.split(suffix, "/")
        authorize(wire, "flow-#{role}-cont-#{version}")
        {204, [], ""}

      {:POST, "/tenant/receiver/incoming-payments"} ->
        authorize(wire, "flow-receiver-resource-1")

        assert payload == %{
                 "walletAddress" => base <> "/wallets/receiver",
                 "incomingAmount" => @receive
               }

        incoming = %{
          "id" => base <> path <> "/in-1",
          "walletAddress" => payload["walletAddress"],
          "incomingAmount" => @receive,
          "receivedAmount" => %{@receive | "value" => "0"},
          "completed" => false,
          "createdAt" => @created,
          "methods" => [
            %{
              "type" => "ilp",
              "ilpAddress" => "g.test.receiver",
              "sharedSecret" => "flow-ilp-secret"
            }
          ]
        }

        Process.put(:incoming, incoming)
        json(201, incoming)

      {:GET, "/tenant/receiver/incoming-payments/in-1"} ->
        incoming = Process.get(:incoming)

        if wire.headers["authorization"] do
          authorize(wire, "flow-receiver-resource-1")
          json(200, incoming)
        else
          json(
            200,
            incoming
            |> Map.delete("walletAddress")
            |> Map.put("authServer", base <> "/auth/receiver?tenant=a%2Bb")
          )
        end

      {:POST, "/tenant/receiver/incoming-payments/in-1/complete"} ->
        authorize(wire, "flow-receiver-resource-1")
        incoming = Process.get(:incoming) |> Map.put("completed", true)
        assert incoming["receivedAmount"] == @receive
        Process.put(:incoming, incoming)
        json(200, Map.delete(incoming, "methods"))

      {:GET, "/tenant/receiver/incoming-payments"} ->
        authorize(wire, "flow-receiver-resource-1")

        assert URI.decode_query(URI.parse(wire.target).query) == %{
                 "wallet-address" => base <> "/wallets/receiver"
               }

        json(200, page(Map.delete(Process.get(:incoming), "methods")))

      {:POST, "/tenant/sender/quotes"} ->
        authorize(wire, Process.get(:sender_token))

        assert payload == %{
                 "walletAddress" => base <> "/wallets/sender",
                 "receiver" => Process.get(:incoming)["id"],
                 "method" => "ilp"
               }

        quote = %{
          "id" => base <> path <> "/q-1?part=a%2Bb",
          "walletAddress" => payload["walletAddress"],
          "receiver" => payload["receiver"],
          "debitAmount" => @debit,
          "receiveAmount" => @receive,
          "method" => "ilp",
          "createdAt" => @created
        }

        Process.put(:quote, quote)
        json(201, quote)

      {:GET, "/tenant/sender/quotes/q-1"} ->
        authorize(wire, Process.get(:sender_token))
        json(200, Process.get(:quote))

      {:POST, "/tenant/sender/outgoing-payments"} ->
        authorize(wire, "flow-sender-resource-2")
        assert payload["walletAddress"] == base <> "/wallets/sender"

        if payload["quoteId"] do
          assert payload["quoteId"] == Process.get(:quote)["id"]
        else
          assert payload["incomingPayment"] == Process.get(:incoming)["id"]
          assert payload["debitAmount"] == @debit
        end

        outgoing = %{
          "id" => base <> path <> "/out-1?part=a%2Bb",
          "walletAddress" => payload["walletAddress"],
          "receiver" => Process.get(:incoming)["id"],
          "debitAmount" => @debit,
          "receiveAmount" => @receive,
          "sentAmount" => @debit,
          "failed" => false,
          "createdAt" => @created,
          "metadata" => payload["metadata"]
        }

        Process.put(:outgoing, outgoing)
        Process.put(:incoming, Map.put(Process.get(:incoming), "receivedAmount", @receive))

        json(
          201,
          Map.merge(outgoing, %{
            "grantSpentDebitAmount" => @debit,
            "grantSpentReceiveAmount" => @receive
          })
        )

      {:GET, "/tenant/sender/outgoing-payments/out-1"} ->
        authorize(wire, "flow-sender-resource-2")
        json(200, Process.get(:outgoing))

      {:GET, "/tenant/sender/outgoing-payments"} ->
        authorize(wire, "flow-sender-resource-2")

        assert URI.decode_query(URI.parse(wire.target).query) == %{
                 "wallet-address" => base <> "/wallets/sender",
                 "first" => "1"
               }

        json(200, page(Process.get(:outgoing)))

      {:GET, "/tenant/sender/outgoing-payment-grant"} ->
        authorize(wire, "flow-sender-resource-2")
        assert wire.target == path
        json(200, %{"spentDebitAmount" => @debit, "spentReceiveAmount" => @receive})
    end
  end

  defp continuation(base, role, version),
    do: %{
      "uri" => base <> "/continue/#{role}/#{version}?part=a%2Bb",
      "access_token" => %{"value" => "flow-#{role}-cont-#{version}"},
      "wait" => 0
    }

  defp token(base, role, version),
    do: %{
      "value" => "flow-#{role}-resource-#{version}",
      "manage" => base <> "/manage/#{role}/#{version}?part=a%2Bb",
      "access" => Process.get({:access, role})
    }

  defp authorize(wire, token) do
    assert is_binary(token)
    assert wire.headers["authorization"] == "GNAP " <> token
  end

  defp json(status, body), do: {status, [], Jason.encode!(body)}

  defp page(item),
    do: %{
      "pagination" => %{"hasNextPage" => false, "hasPreviousPage" => false},
      "result" => [item]
    }

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp export_token(session, path) do
    File.write!(path, load(session)["response"]["access_token"]["value"] <> "\n")
    File.chmod!(path, 0o600)
    path
  end

  defp run(args, payload \\ nil) do
    {stdout, ""} = invoke(args, payload, 0)
    Jason.decode!(stdout)
  end

  defp invoke(args, payload, expected) do
    input = if payload, do: Jason.encode!(payload), else: ""

    {stdout, stderr, status} =
      case System.get_env("OPEN_PAYMENTS_TEST_EXECUTABLE") do
        nil ->
          stderr =
            capture_io(:stderr, fn ->
              stdout =
                capture_io([input: input], fn ->
                  send(self(), {:exit_status, CLI.run(args ++ ["--allow-http", "--json"])})
                end)

              send(self(), {:stdout, stdout})
            end)

          assert_received {:stdout, stdout}
          assert_received {:exit_status, status}
          {stdout, stderr, status}

        executable ->
          OpenPaymentsSnippets.Test.Executable.run(
            executable,
            args ++ ["--allow-http", "--json"],
            input
          )
      end

    assert status == expected, "Command #{inspect(args)} returned #{status}: #{stderr}"

    for secret <- [
          "flow-sender-resource-",
          "flow-receiver-resource-",
          "flow-sender-cont-",
          "flow-receiver-cont-",
          "flow-ilp-secret",
          @client_nonce,
          @server_nonce,
          @reference,
          "PRIVATE KEY",
          "wrong-environment-token"
        ] do
      refute stdout <> stderr =~ secret
    end

    {stdout, stderr}
  end

  defp drain do
    receive do
      {:http_request, wire} -> [wire | drain()]
    after
      0 -> []
    end
  end

  defp verify_wire(wire) do
    public? =
      String.starts_with?(wire.target, "/wallets/") or
        (String.starts_with?(wire.target, "/tenant/receiver/incoming-payments/in-1") and
           wire.method == :GET and is_nil(wire.headers["authorization"]))

    if public? do
      refute Map.has_key?(wire.headers, "authorization")
      refute Map.has_key?(wire.headers, "signature")
    else
      "sig1=" <> params = wire.headers["signature-input"]
      [_, signature] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

      fields = [
        ~s("@method": #{wire.method}),
        ~s("@target-uri": http://#{wire.headers["host"]}#{wire.target})
      ]

      fields =
        if wire.headers["authorization"],
          do: fields ++ [~s("authorization": #{wire.headers["authorization"]})],
          else: fields

      fields =
        if wire.body == "",
          do: fields,
          else:
            fields ++
              [
                ~s("content-digest": #{wire.headers["content-digest"]}),
                ~s("content-length": #{wire.headers["content-length"]}),
                ~s("content-type": #{wire.headers["content-type"]})
              ]

      if wire.body != "" do
        assert wire.headers["content-digest"] ==
                 "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"

        assert wire.headers["content-length"] == Integer.to_string(byte_size(wire.body))
      end

      message = Enum.join(fields ++ [~s("@signature-params": #{params})], "\n")

      assert :crypto.verify(:eddsa, :none, message, Base.decode64!(signature), [@public, :ed25519])
    end
  end
end
