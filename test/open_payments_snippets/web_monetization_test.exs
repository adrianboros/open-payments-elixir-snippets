defmodule OpenPaymentsSnippets.WebMonetizationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import OpenPaymentsSnippets.Test.PaymentMetadata
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.{Executable, HTTPServer}

  @moduletag :consumer_flow
  @moduletag timeout: 180_000
  # Public RFC 8032 vector 1.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """

  setup do
    directory = Path.join(System.tmp_dir!(), "op-wm-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    key = Path.join(directory, "key.pem")
    File.write!(key, @pem)
    File.chmod!(key, 0o600)

    names =
      ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 ACCESS_TOKEN TEST_SCENARIO TEST_RUN_ID)

    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    System.put_env("KEY_ID", "wm-key")
    System.put_env("PRIVATE_KEY_FILE", key)
    System.put_env("TEST_SCENARIO", "web-monetization")
    System.put_env("TEST_RUN_ID", "wm-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(directory)

      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    %{directory: directory}
  end

  for {sender, receiver, sender_scale, receiver_scale} <- [
        {"EUR", "EUR", 2, 2},
        {"GBP", "EUR", 2, 2},
        {"EUR", "GBP", 2, 2},
        {"JPY", "EUR", 0, 3},
        {"EUR", "EUR", 9, 9}
      ] do
    test "open incoming payment accepts repeated #{sender}->#{receiver} contributions at scale #{sender_scale}/#{receiver_scale}, reuses an hourly budget, tracks receipts and completes",
         c do
      base =
        HTTPServer.start(
          &route(
            &1,
            {unquote(sender), unquote(receiver), unquote(sender_scale), unquote(receiver_scale)}
          )
        )

      System.put_env("WALLET_ADDRESS", base <> "/wallets/sender")
      receiver_token = grant(c.directory, base, "receiver")
      sender_token = grant(c.directory, base, "sender")
      template = Path.expand("../../examples/web-monetization-incoming.json", __DIR__)

      incoming =
        run(
          [
            "incoming",
            "create",
            template,
            "--var",
            "RECEIVER_WALLET_URL=" <> base <> "/wallets/receiver"
          ],
          nil,
          receiver_token
        )

      incoming_id = incoming["id"]
      refute Map.has_key?(incoming, "incomingAmount")
      refute incoming["completed"]
      assert incoming["methods"] |> hd() |> Map.fetch!("sharedSecret") == "[REDACTED]"

      assert incoming["metadata"]["openPaymentsSnippets"]["runId"] ==
               System.fetch_env!("TEST_RUN_ID")

      assert run(["incoming", "get-public", incoming_id])["receivedAmount"]["value"] == "0"

      template = Path.expand("../../examples/web-monetization-outgoing.json", __DIR__)

      for total <- 1..8 do
        value = "1"
        total = Integer.to_string(total)

        outgoing =
          run(
            [
              "outgoing",
              "create",
              template,
              "--var",
              "SENDER_WALLET_URL=" <> base <> "/wallets/sender",
              "--var",
              "INCOMING_PAYMENT_URL=" <> incoming_id,
              "--var",
              "DEBIT_VALUE=" <> value,
              "--var",
              "SENDER_ASSET_CODE=#{unquote(sender)}",
              "--var",
              "SENDER_ASSET_SCALE=#{unquote(sender_scale)}"
            ],
            nil,
            sender_token
          )

        assert outgoing["failed"] == false

        assert outgoing["metadata"]["openPaymentsSnippets"] ==
                 incoming["metadata"]["openPaymentsSnippets"]

        assert outgoing["grantSpentDebitAmount"]["value"] == total

        assert run(["outgoing", "get", outgoing["id"]], nil, sender_token)["sentAmount"]["value"] ==
                 value

        receipt = run(["incoming", "get-public", incoming_id])
        assert receipt["receivedAmount"]["value"] == total
        refute receipt["completed"]
      end

      spent = run(["outgoing", "grant-spent-amounts"], nil, sender_token)
      assert spent["spentDebitAmount"] == amount(unquote(sender), unquote(sender_scale), "8")

      assert spent["spentReceiveAmount"] ==
               amount(unquote(receiver), unquote(receiver_scale), "8")

      completed = run(["incoming", "complete", incoming_id], nil, receiver_token)
      assert completed["completed"]
      assert completed["receivedAmount"]["value"] == "8"
      assert run(["incoming", "get-public", incoming_id])["completed"]

      # A provider rejection ends the invocation; it must not silently retry.
      payload = %{
        "walletAddress" => base <> "/wallets/sender",
        "incomingPayment" => incoming_id,
        "debitAmount" => amount(unquote(sender), unquote(sender_scale), "1")
      }

      assert {"", error, 1} =
               invoke(["outgoing", "create", "-", "--access-token-file", sender_token], payload)

      assert error =~ "HTTP 409"
      requests = drain()

      posts =
        Enum.filter(
          requests,
          &(&1.method == :POST and &1.target == "/resources/sender/outgoing-payments")
        )

      assert length(posts) == 9
      sender_grants = Enum.filter(requests, &(&1.method == :POST and &1.target == "/auth/sender"))
      assert length(sender_grants) == 1
      [grant_wire] = sender_grants

      limits =
        Jason.decode!(grant_wire.body)["access_token"]["access"] |> hd() |> Map.fetch!("limits")

      assert limits["interval"] == "R/2026-11-24T00:00:00Z/PT1H"

      assert limits["debitAmount"] ==
               amount(
                 unquote(sender),
                 unquote(sender_scale),
                 Integer.to_string(10 * Integer.pow(10, unquote(sender_scale)))
               )

      assert String.to_integer(spent["spentDebitAmount"]["value"]) <
               String.to_integer(limits["debitAmount"]["value"])

      assert Enum.all?(
               posts,
               &(Jason.decode!(&1.body)["metadata"]["openPaymentsSnippets"]["scenario"] ==
                   "web-monetization")
             )

      assert length(
               Enum.filter(requests, &(&1.target == "/resources/receiver/incoming-payments"))
             ) == 1

      refute Enum.any?(requests, &String.contains?(&1.target, "/quotes"))
      refute_receive {:http_request, _}, 20

      for role <- ["receiver", "sender"] do
        assert run(["token", "revoke", Path.join(c.directory, role <> ".json")])["status"] ==
                 "revoked"
      end
    end
  end

  defp grant(directory, base, role) do
    path = Path.join(directory, role <> ".json")
    type = if role == "receiver", do: "incoming-payment", else: "outgoing-payment"
    actions = if role == "receiver", do: ["create", "read", "complete"], else: ["create", "read"]
    access = %{"type" => type, "actions" => actions, "identifier" => base <> "/wallets/" <> role}

    access =
      if role == "sender",
        do:
          Map.put(access, "limits", %{
            "debitAmount" => budget_for_wallet(base),
            "interval" => "R/2026-11-24T00:00:00Z/PT1H"
          }),
        else: access

    payload = %{"client" => base <> "/wallets/sender", "access_token" => %{"access" => [access]}}

    assert run(
             [
               "grant",
               "request",
               "-",
               "--wallet-address",
               base <> "/wallets/" <> role,
               "--output",
               path
             ],
             payload
           )["status"] == "approved"

    session = path |> File.read!() |> Jason.decode!()
    token_path = Path.join(directory, role <> "-token.txt")
    File.write!(token_path, session["response"]["access_token"]["value"])
    File.chmod!(token_path, 0o600)
    token_path
  end

  defp budget_for_wallet(base) do
    wallet = run(["wallet", "get", base <> "/wallets/sender"])

    amount(
      wallet["assetCode"],
      wallet["assetScale"],
      Integer.to_string(10 * Integer.pow(10, wallet["assetScale"]))
    )
  end

  defp route(wire, {sender, receiver, sender_scale, receiver_scale}) do
    base = "http://" <> wire.headers["host"]
    data = if wire.body == "", do: nil, else: Jason.decode!(wire.body)

    if Map.has_key?(wire.headers, "authorization") or wire.method != :GET do
      assert wire.headers["signature-input"] =~ "wm-key"
      assert is_binary(wire.headers["signature"])

      if wire.body != "",
        do:
          assert(
            wire.headers["content-digest"] ==
              "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"
          )
    end

    case {wire.method, wire.target} do
      {:GET, "/wallets/" <> role} ->
        {code, scale} =
          if role == "sender", do: {sender, sender_scale}, else: {receiver, receiver_scale}

        json(200, %{
          "id" => base <> "/wallets/" <> role,
          "assetCode" => code,
          "assetScale" => scale,
          "authServer" => base <> "/auth/" <> role,
          "resourceServer" => base <> "/resources/" <> role
        })

      {:POST, "/auth/" <> role} ->
        Process.put({:access, role}, data["access_token"]["access"])

        json(200, %{
          "continue" => %{
            "uri" => base <> "/continue/" <> role,
            "access_token" => %{"value" => "wm-cont-" <> role},
            "wait" => 0
          },
          "access_token" => %{
            "value" => "wm-#{role}-token",
            "manage" => base <> "/manage/" <> role,
            "access" => data["access_token"]["access"]
          }
        })

      {:POST, "/resources/receiver/incoming-payments"} ->
        assert wire.headers["authorization"] == "GNAP wm-receiver-token"

        assert_enriched(data, %{
          "walletAddress" => base <> "/wallets/receiver",
          "metadata" => %{
            "description" =>
              "Open Payments via Elixir SDK - Web Monetization open incoming payment",
            "testScenario" => "web-monetization"
          }
        })

        incoming =
          Map.merge(data, %{
            "id" => base <> wire.target <> "/stream",
            "completed" => false,
            "receivedAmount" => amount(receiver, receiver_scale, "0"),
            "createdAt" => "2026-11-24T00:00:00Z",
            "methods" => [
              %{"type" => "ilp", "ilpAddress" => "g.test.wm", "sharedSecret" => "wm-ilp-secret"}
            ]
          })

        Process.put(:incoming, incoming)
        json(201, incoming)

      {:GET, "/resources/receiver/incoming-payments/stream"} ->
        json(
          200,
          Process.get(:incoming)
          |> Map.delete("walletAddress")
          |> Map.put("authServer", base <> "/auth/receiver")
        )

      {:POST, "/resources/sender/outgoing-payments"} ->
        assert wire.headers["authorization"] == "GNAP wm-sender-token"
        incoming = Process.get(:incoming)
        assert data["incomingPayment"] == incoming["id"]

        assert data["metadata"]["openPaymentsSnippets"] ==
                 incoming["metadata"]["openPaymentsSnippets"]

        if incoming["completed"] do
          json(409, %{"error" => "incoming payment complete"})
        else
          value = data["debitAmount"]["value"]
          total = Process.get(:spent, 0) + String.to_integer(value)
          [access] = Process.get({:access, "sender"})
          assert total <= String.to_integer(access["limits"]["debitAmount"]["value"])
          Process.put(:spent, total)

          Process.put(
            :incoming,
            Map.put(
              incoming,
              "receivedAmount",
              amount(receiver, receiver_scale, to_string(total))
            )
          )

          outgoing = %{
            "id" => base <> wire.target <> "/#{total}",
            "walletAddress" => data["walletAddress"],
            "receiver" => incoming["id"],
            "debitAmount" => data["debitAmount"],
            "receiveAmount" => amount(receiver, receiver_scale, value),
            "sentAmount" => data["debitAmount"],
            "failed" => false,
            "createdAt" => "2026-11-24T00:00:00Z",
            "metadata" => data["metadata"]
          }

          Process.put({:outgoing, to_string(total)}, outgoing)

          json(
            201,
            Map.merge(outgoing, %{
              "grantSpentDebitAmount" => amount(sender, sender_scale, to_string(total)),
              "grantSpentReceiveAmount" => amount(receiver, receiver_scale, to_string(total))
            })
          )
        end

      {:GET, "/resources/sender/outgoing-payments/" <> id} ->
        json(200, Process.get({:outgoing, id}))

      {:GET, "/resources/sender/outgoing-payment-grant"} ->
        json(200, %{
          "spentDebitAmount" => amount(sender, sender_scale, to_string(Process.get(:spent))),
          "spentReceiveAmount" => amount(receiver, receiver_scale, to_string(Process.get(:spent)))
        })

      {:POST, "/resources/receiver/incoming-payments/stream/complete"} ->
        assert wire.headers["authorization"] == "GNAP wm-receiver-token"
        incoming = Process.get(:incoming) |> Map.put("completed", true)
        Process.put(:incoming, incoming)
        json(200, Map.delete(incoming, "methods"))

      {:DELETE, "/manage/" <> role} ->
        assert wire.headers["authorization"] == "GNAP wm-#{role}-token"
        {204, [], ""}
    end
  end

  defp amount(code, scale, value),
    do: %{"assetCode" => code, "assetScale" => scale, "value" => value}

  defp json(status, data),
    do: {status, [{"Content-Type", "application/json"}], Jason.encode!(data)}

  defp run(arguments, payload \\ nil, token \\ nil) do
    arguments = if token, do: arguments ++ ["--access-token-file", token], else: arguments
    assert {stdout, "", 0} = invoke(arguments, payload)
    Jason.decode!(stdout)
  end

  defp invoke(arguments, payload) do
    arguments = arguments ++ ["--allow-http", "--json"]
    input = if payload, do: Jason.encode!(payload), else: ""

    case System.get_env("OPEN_PAYMENTS_TEST_EXECUTABLE") do
      nil ->
        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io([input: input], fn -> send(self(), {:status, CLI.run(arguments)}) end)

            send(self(), {:stdout, stdout})
          end)

        assert_received {:stdout, stdout}
        assert_received {:status, status}
        {stdout, stderr, status}

      executable ->
        Executable.run(executable, arguments, input)
    end
  end

  defp drain do
    receive do
      {:http_request, wire} -> [wire | drain()]
    after
      0 -> []
    end
  end
end
