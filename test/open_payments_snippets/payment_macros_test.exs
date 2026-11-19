defmodule OpenPaymentsSnippets.PaymentMacrosTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.{PaymentMacros, GrantContinuation}
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
        "open-payments-macros-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  @tag :consumer_flow
  test "immediate grants chain six initialization calls and pipe the descriptor into one confirmed outgoing creation",
       c do
    base = server(c.path)
    assert {stdout, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    result = Jason.decode!(stdout)
    assert result["stage"] == "quote-ready" and result["scenario"] == "quote-payment"
    assert result["saved"]

    assert commands(result) == [
             "payment start",
             "payment prepare",
             "payment authorize",
             "payment quote"
           ]

    saved = load(c.path)

    assert saved["payment"]["scenario"]["sender_authorization"] ==
             request(base)["senderAuthorization"]

    assert saved["payment"]["scenario"]["version"] == 1

    assert saved["payment"]["receiver_grant"]["grant_endpoint"] ==
             base <> "/auth/receiver?opaque=a%2Bb"

    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    assert length(drain()) == 6

    assert {stdout, "", 0} =
             invoke(["payment", "finalize", "-", "--yes", "--json", "--allow-http"], stdout)

    result = Jason.decode!(stdout)
    assert result["stage"] == "outgoing-created" and result["saved"]
    assert commands(result) == ["payment finish"]
    assert load(c.path)["payment"]["outgoing_payment"]["id"] == outgoing(base)["id"]

    assert_received {:http_request,
                     %{method: :POST, target: "/resources/sender/outgoing-payments"}}

    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(finalize(c.path))
    assert Jason.decode!(stdout)["saved"] == false
    assert File.read!(c.path) == before
    assert File.read!(c.key) == @pem
    refute File.exists?(c.path <> ".lock")
    refute_receive {:http_request, _}, 20
  end

  @tag :consumer_flow
  test "receiver and sender consent stop cleanly, verify callbacks and resume remaining steps in one command",
       c do
    base = server(c.path, receiver_pending: true, sender_pending: true)
    assert {descriptor, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    result = Jason.decode!(descriptor)

    assert result["stage"] == "receiver-grant" and result["status"] == "pending" and
             result["saved"]

    assert result["consent_url"] == base <> "/consent/receiver"
    assert length(drain()) == 3
    assert {waiting, "", 0} = invoke(finalize(c.path))
    assert Jason.decode!(waiting)["status"] == "pending"
    refute Jason.decode!(waiting)["saved"]
    refute_received {:http_request, _}
    receiver = load(c.path)
    returned = callback(receiver, "receiver")
    before = File.read!(c.path)

    assert {"", _, 2} =
             invoke(
               finalize(c.path) ++ ["--callback-file", "-"],
               String.replace(returned, "state=receiver", "state=wrong")
             )

    assert File.read!(c.path) == before
    refute_received {:http_request, _}
    assert {stdout, "", 0} = invoke(finalize(c.path) ++ ["--callback-file", "-"], returned)
    result = Jason.decode!(stdout)
    assert result["stage"] == "sender-grant" and result["status"] == "pending"
    assert commands(result) == ["grant continue", "payment prepare", "payment authorize"]
    assert load(c.path)["payment"]["receiver_grant"]["callback_verified"]
    refute load(c.path)["callback_verified"]
    assert length(drain()) == 3
    file = Path.join(c.directory, "sender-callback.txt")
    File.write!(file, callback(load(c.path), "sender"))

    assert {stdout, "", 0} =
             invoke(
               [
                 "payment",
                 "finalize",
                 "-",
                 "--callback-file",
                 file,
                 "--yes",
                 "--json",
                 "--allow-http"
               ],
               descriptor
             )

    result = Jason.decode!(stdout)
    assert result["stage"] == "outgoing-created"
    assert commands(result) == ["grant continue", "payment quote", "payment finish"]
    assert load(c.path)["callback_verified"]
    wires = drain()

    assert Enum.map(wires, & &1.target) == [
             "/continue/sender?opaque=a%2Bb",
             "/resources/sender/quotes",
             "/resources/sender/outgoing-payments"
           ]

    assert File.read!(c.key) == @pem
  end

  @tag :consumer_flow
  test "the same pipeline supports a self-payment scenario with a shared wallet", c do
    base = server(c.path, self_wallet: true)

    input =
      request(base)
      |> Map.put("receiver", base <> "/wallets/sender")
      |> Map.put("receiveAmount", amount("USD", "100"))

    {result, stderr, status} =
      case System.get_env("OPEN_PAYMENTS_TEST_EXECUTABLE") do
        nil ->
          assert {descriptor, "", 0} = invoke(initialize(c.path), Jason.encode!(input))
          invoke(["payment", "finalize", "-", "--yes", "--json", "--allow-http"], descriptor)

        executable ->
          script =
            ~s("$1" payment initialize - --output "$2" --json --allow-http | "$1" payment finalize - --yes --json --allow-http)

          OpenPaymentsSnippets.Test.Executable.run(
            "/bin/sh",
            ["-c", script, "macro-pipe", executable, c.path],
            Jason.encode!(input)
          )
      end

    assert stderr == "" and status == 0
    refute result <> stderr =~ "test-"
    assert Jason.decode!(result)["stage"] == "outgoing-created"
    saved = load(c.path)
    assert saved["payment"]["incoming_payment"]["walletAddress"] == base <> "/wallets/sender"
    assert saved["payment"]["quote"]["receiveAmount"]["assetCode"] == "USD"
    assert length(drain()) == 7
  end

  test "waits are reported without sleeping, consuming callbacks or issuing extra requests", c do
    base = server(c.path, receiver_pending: true, wait: 3600)
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(finalize(c.path) ++ ["--callback-file", "absent-callback"])
    result = Jason.decode!(stdout)
    assert result["status"] == "waiting" and result["wait_seconds"] > 0
    assert result["saved"] == false
    assert commands(result) == ["grant continue"]
    assert File.read!(c.path) == before
    assert length(drain()) == 3
  end

  test "wait-only continuation stops once even when the server says wait zero", c do
    base = server(c.path, receiver_pending: true, wait_only: "receiver")
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))

    assert {stdout, "", 0} =
             invoke(
               finalize(c.path) ++ ["--callback-file", "-"],
               callback(load(c.path), "receiver")
             )

    result = Jason.decode!(stdout)
    assert result["status"] == "pending" and result["stage"] == "receiver-grant"
    assert commands(result) == ["grant continue"]
    assert length(drain()) == 4
  end

  test "initialization stops at sender consent and finalization resumes the payment",
       c do
    base = server(c.path, sender_pending: true)

    args = [
      "payment",
      "initialize",
      "-",
      "--output",
      c.path,
      "--json",
      "--allow-http"
    ]

    assert {stdout, "", 0} = invoke(args, Jason.encode!(request(base)))
    result = Jason.decode!(stdout)
    assert result["status"] == "pending" and result["stage"] == "sender-grant"
    assert commands(result) == ["payment start", "payment prepare", "payment authorize"]
    refute Map.has_key?(load(c.path)["payment"], "quote")
    assert length(drain()) == 5

    assert {stdout, "", 0} =
             invoke(
               [
                 "payment",
                 "finalize",
                 c.path,
                 "--callback-file",
                 "-",
                 "--allow-http",
                 "--yes",
                 "--json"
               ],
               callback(load(c.path), "sender")
             )

    assert Jason.decode!(stdout)["stage"] == "outgoing-created"
    assert length(drain()) == 3
  end

  test "manual grant continuation and rotation can be followed by macro finalization", c do
    base = server(c.path, sender_pending: true)
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))

    assert {_, "", 0} =
             invoke(
               ["grant", "continue", c.path, "--callback-file", "-", "--allow-http"],
               callback(load(c.path), "sender")
             )

    assert {_, "", 0} = invoke(["token", "rotate", c.path, "--allow-http"])
    assert {stdout, "", 0} = invoke(finalize(c.path))
    assert commands(Jason.decode!(stdout)) == ["payment quote", "payment finish"]
    assert load(c.path)["response"]["access_token"]["value"] == "test-sender-rotated-secret"
    assert length(drain()) == 9
  end

  test "confirmation decline preserves the ready quote and JSON creation still needs yes", c do
    base = server(c.path)
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    before = File.read!(c.path)
    assert {"", _, 2} = invoke(["payment", "finalize", c.path, "--allow-http", "--json"])
    assert {stdout, stderr, 0} = invoke(["payment", "finalize", c.path, "--allow-http"], "no\n")
    assert stdout =~ "Payment not sent" and stdout =~ "Steps  payment finish (declined)"
    assert stderr =~ "Type send"
    assert File.read!(c.path) == before
    assert length(drain()) == 6
  end

  test "unused callbacks and two stdin inputs are rejected before further operations", c do
    base = server(c.path)
    assert {descriptor, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    before = File.read!(c.path)
    assert {"", _, 2} = invoke(finalize(c.path) ++ ["--callback-file", "private-unused-callback"])

    assert {"", _, 2} =
             invoke(
               ["payment", "finalize", "-", "--callback-file", "-", "--yes", "--allow-http"],
               descriptor
             )

    for input <- ["not-json", "{}", "[]", ~s({"session":null})] do
      assert {"", _, 2} = invoke(["payment", "finalize", "-", "--yes"], input)
    end

    assert File.read!(c.path) == before
    assert length(drain()) == 6
  end

  test "invalid combined input fails before discovery or creating a private file", c do
    base = server(c.path)

    for input <- [
          nil,
          [],
          %{},
          Map.delete(request(base), "senderAuthorization"),
          Map.put(request(base), "unknown", true),
          put_in(request(base), ["senderAuthorization", "debitAmount", "value"], 1.5),
          put_in(request(base), ["senderAuthorization", "finishUri"], "not-uri"),
          Map.put(request(base), "receiveAmount", nil)
        ] do
      assert {"", _, 2} = invoke(initialize(c.path), Jason.encode!(input))
      refute File.exists?(c.path)
    end

    assert {"", _, 2} = invoke(initialize(c.path), <<255>>)

    assert {"", _, 2} =
             invoke(["payment", "initialize", "-", "--allow-http"], Jason.encode!(request(base)))

    refute_received {:http_request, _}
  end

  test "existing output, private-file rules, recorded identity and plain non-macro sessions fail safely",
       c do
    base = server(c.path)
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    before = File.read!(c.path)
    assert {"", _, 1} = invoke(initialize(c.path), Jason.encode!(request(base)))
    assert File.read!(c.path) == before

    for flags <- [
          ["--key-id", "other"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", "missing-private-key"]
        ] do
      assert {"", _, 2} = invoke(finalize(c.path) ++ flags)
    end

    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(finalize(c.path))
    File.chmod!(c.path, 0o600)
    file = load(c.path) |> update_in(["payment"], &Map.delete(&1, "scenario"))
    File.write!(c.path, Jason.encode!(file))
    assert {"", _, 2} = invoke(finalize(c.path))
    assert length(drain()) == 6
  end

  test "an interrupted intermediate OP call preserves earlier steps and blocks macro replay", c do
    base = server(c.path, fail: "quote")
    assert {"", _, 1} = invoke(initialize(c.path), Jason.encode!(request(base)))
    saved = load(c.path)
    assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-quote"
    assert saved["payment"]["scenario"]["name"] == "quote-payment"
    assert saved["payment"]["incoming_payment"]["id"] == incoming(base)["id"]
    assert {"", _, 2} = invoke(finalize(c.path))
    assert {"", _, 1} = invoke(initialize(c.path), Jason.encode!(request(base)))
    assert length(drain()) == 6
  end

  test "ambiguous outgoing outcomes keep exact state and cannot be replayed by the macro", c do
    base = server(c.path, fail: "outgoing")
    assert {descriptor, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))
    assert {"", _, 1} = invoke(finalize(c.path))
    saved = load(c.path)
    assert saved["state"] == "uncertain" and saved["attempt_operation"] == "payment-finish"
    assert saved["payment"]["outgoing_request"]["quoteId"] == quote_data(base)["id"]

    assert {"", _, 2} =
             invoke(["payment", "finalize", "-", "--yes", "--json", "--allow-http"], descriptor)

    assert length(drain()) == 7
  end

  test "revoked tokens never cause automatic continuation and pending-only checks fail closed",
       c do
    base = server(c.path, sender_pending: true)
    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))

    assert {_, "", 0} =
             invoke(
               ["grant", "continue", c.path, "--callback-file", "-", "--allow-http"],
               callback(load(c.path), "sender")
             )

    assert {:error, {:argument, _}} =
             GrantContinuation.run(c.path, allow_http: true, pending_only: true)

    file =
      load(c.path)
      |> Map.put("kind", "token-revocation")
      |> update_in(["response"], &Map.delete(&1, "access_token"))

    File.write!(c.path, Jason.encode!(file))
    assert {"", _, 2} = invoke(finalize(c.path))
    assert length(drain()) == 6
  end

  test "concurrent finalizers share step transactions and create at most one outgoing payment",
       c do
    owner = self()

    base =
      server(c.path,
        on_outgoing: fn ->
          send(owner, {:waiting, self()})
          receive do: (:release -> :ok)
        end
      )

    assert {_, "", 0} = invoke(initialize(c.path), Jason.encode!(request(base)))

    task =
      Task.async(fn ->
        PaymentMacros.finalize(c.path, allow_http: true, yes: true, json: true)
      end)

    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(finalize(c.path))
    send(server, :release)
    assert {:ok, %{stage: "outgoing-created"}} = Task.await(task)
    assert length(drain()) == 7
  end

  test "unrelated flags are rejected and both macro commands appear in help" do
    for argv <- [
          ["payment", "initialize"],
          ["payment", "finalize"],
          initialize("private-session") ++ ["--yes"],
          initialize("private-session") ++ ["--callback-file", "callback"],
          finalize("private-session") ++ ["--output", "other"],
          finalize("private-session") ++ ["--access-token-file", "private-token"],
          finalize("private-session") ++ ["--first", "1"]
        ] do
      assert {"", _, 2} = invoke(argv)
    end

    for argv <- [["payment", "initialize", "--help"], ["payment", "finalize", "--help"]] do
      assert {stdout, "", 0} = invoke(argv)
      assert stdout =~ "payment initialize" and stdout =~ "payment finalize"
    end

    refute_received {:http_request, _}
  end

  defp initialize(path),
    do: ["payment", "initialize", "-", "--output", path, "--allow-http", "--json"]

  defp finalize(path), do: ["payment", "finalize", path, "--allow-http", "--json", "--yes"]

  defp request(base),
    do: %{
      "receiver" => base <> "/wallets/receiver",
      "receiveAmount" => amount("EUR", "100"),
      "finishUri" => "https://client.example/return?state=receiver",
      "metadata" => %{"memo" => "Café 🌍"},
      "senderAuthorization" => %{
        "debitAmount" => amount("USD", "200"),
        "finishUri" => "https://client.example/return?state=sender"
      }
    }

  defp amount(asset, value), do: %{"value" => value, "assetCode" => asset, "assetScale" => 2}
  defp commands(result), do: Enum.map(result["steps"], & &1["command"])
  defp load(path), do: path |> File.read!() |> Jason.decode!()
  defp origin(wire), do: "http://" <> wire.headers["host"]

  defp json(status, data),
    do: {status, [{"Content-Type", "application/json"}], Jason.encode!(data)}

  defp wallet(base, role) do
    role = if Process.get(:self_wallet), do: "sender", else: role

    %{
      "id" => base <> "/wallets/" <> role,
      "assetCode" => if(role == "sender", do: "USD", else: "EUR"),
      "assetScale" => 2,
      "authServer" => base <> "/auth/" <> role <> "?opaque=a%2Bb",
      "resourceServer" => base <> "/resources/" <> role
    }
  end

  defp continuation(base, role, wait),
    do: %{
      "uri" => base <> "/continue/" <> role <> "?opaque=a%2Bb",
      "access_token" => %{"value" => "test-" <> role <> "-cont-secret"},
      "wait" => wait
    }

  defp approved(base, role),
    do: %{"continue" => continuation(base, role, 0), "access_token" => token(base, role)}

  defp token(base, role),
    do: %{
      "value" =>
        if(Process.get({:rotated, role}),
          do: "test-#{role}-rotated-secret",
          else: "test-#{role}-issued-secret"
        ),
      "manage" => base <> "/manage/" <> role,
      "access" => Process.get({:access, role}, [])
    }

  defp incoming(base),
    do: %{
      "id" => wallet(base, "receiver")["resourceServer"] <> "/incoming-payments/id?opaque=a%2Bb",
      "walletAddress" => wallet(base, "receiver")["id"],
      "completed" => false,
      "incomingAmount" => amount(wallet(base, "receiver")["assetCode"], "100"),
      "receivedAmount" => amount(wallet(base, "receiver")["assetCode"], "0"),
      "createdAt" => "2026-11-19T12:00:00Z",
      "methods" => [
        %{
          "type" => "ilp",
          "ilpAddress" => "g.example.receiver",
          "sharedSecret" => "test-ilp-secret"
        }
      ]
    }

  defp quote_data(base),
    do: %{
      "id" => base <> "/resources/sender/quotes/id?opaque=a%2Bb",
      "walletAddress" => base <> "/wallets/sender",
      "receiver" => incoming(base)["id"],
      "debitAmount" => amount("USD", "150"),
      "receiveAmount" => incoming(base)["incomingAmount"],
      "method" => "ilp",
      "createdAt" => "2026-11-19T12:00:00Z"
    }

  defp outgoing(base),
    do: %{
      "id" => base <> "/resources/sender/outgoing-payments/id?opaque=a%2Bb",
      "walletAddress" => base <> "/wallets/sender",
      "receiver" => incoming(base)["id"],
      "quoteId" => quote_data(base)["id"],
      "debitAmount" => amount("USD", "150"),
      "receiveAmount" => incoming(base)["incomingAmount"],
      "sentAmount" => amount("USD", "0"),
      "failed" => false,
      "createdAt" => "2026-11-19T12:00:00Z"
    }

  defp callback(session, role) do
    hash =
      :crypto.hash(
        :sha256,
        Enum.join(
          [
            session["finish"]["nonce"],
            "test-#{role}-nonce",
            "test-reference",
            session["grant_endpoint"]
          ],
          "\n"
        )
      )
      |> Base.encode64()

    session["finish"]["uri"] <>
      "&" <> URI.encode_query(%{"hash" => hash, "interact_ref" => "test-reference"})
  end

  defp server(path, options \\ []) do
    base =
      HTTPServer.start(fn wire ->
        base = origin(wire)
        Process.put(:self_wallet, options[:self_wallet] == true)

        if wire.method == :GET do
          refute Map.has_key?(wire.headers, "signature")

          json(
            200,
            wallet(base, if(wire.target == "/wallets/sender", do: "sender", else: "receiver"))
          )
        else
          assert valid_signature?(wire)
          assert load(path)["payment"]["scenario"]["name"] == "quote-payment"

          cond do
            String.starts_with?(wire.target, "/auth/") ->
              refute Map.has_key?(wire.headers, "authorization")
              data = Jason.decode!(wire.body)

              role =
                if Enum.any?(data["access_token"]["access"], &(&1["type"] == "incoming-payment")),
                  do: "receiver",
                  else: "sender"

              Process.put({:access, role}, data["access_token"]["access"])
              assert data["client"] == base <> "/wallets/sender"

              if role == "sender" do
                assert Enum.map(data["access_token"]["access"], & &1["type"]) == [
                         "quote",
                         "outgoing-payment"
                       ]

                assert List.last(data["access_token"]["access"])["limits"] == %{
                         "debitAmount" => amount("USD", "200"),
                         "receiver" => incoming(base)["id"]
                       }
              end

              if if(role == "sender",
                   do: options[:sender_pending],
                   else: options[:receiver_pending]
                 ) do
                json(200, %{
                  "continue" => continuation(base, role, options[:wait] || 0),
                  "interact" => %{
                    "redirect" => base <> "/consent/" <> role,
                    "finish" => "test-#{role}-nonce"
                  }
                })
              else
                json(200, approved(base, role))
              end

            String.starts_with?(wire.target, "/continue/") ->
              role =
                if String.starts_with?(wire.target, "/continue/sender"),
                  do: "sender",
                  else: "receiver"

              assert wire.headers["authorization"] == "GNAP test-#{role}-cont-secret"

              if options[:wait_only] == role,
                do: json(200, %{"continue" => continuation(base, role, 0)}),
                else: json(200, approved(base, role))

            base <> wire.target ==
                wallet(base, "receiver")["resourceServer"] <> "/incoming-payments" ->
              assert wire.headers["authorization"] == "GNAP test-receiver-issued-secret"
              json(201, incoming(base))

            wire.target == "/resources/sender/quotes" ->
              assert wire.headers["authorization"] == "GNAP " <> token(base, "sender")["value"]
              if options[:fail] == "quote", do: :close, else: json(201, quote_data(base))

            wire.target == "/resources/sender/outgoing-payments" ->
              assert wire.headers["authorization"] == "GNAP " <> token(base, "sender")["value"]

              assert Jason.decode!(wire.body) == %{
                       "walletAddress" => base <> "/wallets/sender",
                       "quoteId" => quote_data(base)["id"]
                     }

              if options[:on_outgoing], do: options[:on_outgoing].()
              if options[:fail] == "outgoing", do: :close, else: json(201, outgoing(base))

            wire.target == "/manage/sender" ->
              Process.put({:rotated, "sender"}, true)
              json(200, %{"access_token" => token(base, "sender")})
          end
        end
      end)

    System.put_env("WALLET_ADDRESS", base <> "/wallets/sender")
    base
  end

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
          "test-receiver-nonce",
          "test-receiver-issued-secret",
          "test-receiver-cont-secret",
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
