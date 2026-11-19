defmodule OpenPaymentsSnippets.PaymentStartTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.Commands.PaymentStart

  alias OpenPaymentsSnippets.CLI
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
        "open-payments-start-#{System.pid()}-#{System.unique_integer([:positive])}"
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

    %{directory: directory, key: key}
  end

  test "discovers both wallets then requests receiver authorization with a fresh nonce and private durable state",
       c do
    output = Path.join(c.directory, "session.json")

    base =
      server(fn wire ->
        saved = load(output)
        assert saved["state"] == "in-flight" and saved["attempt_operation"] == "payment-start"
        assert (File.stat!(output).mode &&& 0o777) == 0o600
        assert (File.stat!(output <> ".lock").mode &&& 0o777) == 0o600
        assert valid_signature?(wire)
        refute Map.has_key?(wire.headers, "authorization")
        request = Jason.decode!(wire.body)
        assert request["client"] == origin(wire) <> "/sender"

        assert request["access_token"]["access"] == [
                 %{
                   "type" => "incoming-payment",
                   "actions" => ["create", "read"],
                   "identifier" => origin(wire) <> "/receiver-canonical"
                 }
               ]

        finish = request["interact"]["finish"]

        assert finish["method"] == "redirect" and
                 finish["uri"] == "https://client.example/return?state=local-state"

        assert byte_size(Base.url_decode64!(finish["nonce"], padding: false)) == 32
        assert saved["finish"] == finish
        json(200, pending(origin(wire)))
      end)

    input = Path.join(c.directory, "request.json")
    data = Map.put(intent(base), "metadata", %{"memo" => "Café 🌍"})
    File.write!(input, Jason.encode!(data))
    assert {stdout, "", 0} = invoke(args(input, output) ++ ["--json"])

    assert Jason.decode!(stdout) == %{
             "status" => "pending",
             "stage" => "receiver-grant",
             "saved" => true,
             "session" => output,
             "consent_url" => base <> "/consent/receiver"
           }

    saved = load(output)
    assert saved["kind"] == "grant-request" and saved["state"] == "ready"
    assert saved["signing_jwk"]["kid"] == "test-key"
    assert saved["grant_endpoint"] == base <> "/issuer/receiver?part=a%2Bb"
    assert saved["payment"]["version"] == 1 and saved["payment"]["stage"] == "receiver-grant"

    assert saved["payment"]["incoming_request"] == %{
             "walletAddress" => base <> "/receiver-canonical",
             "incomingAmount" => amount(),
             "metadata" => data["metadata"]
           }

    assert saved["payment"]["sender_wallet"]["id"] == base <> "/sender-canonical"
    assert saved["payment"]["receiver_wallet"]["resourceServer"] == base <> "/payments/receiver"
    assert saved["response"] == pending(base)
    assert File.read!(input) == Jason.encode!(data)
    refute stdout =~ saved["finish"]["nonce"]
    refute Map.has_key?(saved, "attempted_at")
    refute File.exists?(output <> ".lock")
    assert_three_requests()
  end

  test "UTF-8 stdin and immediate approval save authorization without creating a resource", c do
    base = server(:approved)
    output = Path.join(c.directory, "approved.json")
    assert {stdout, "", 0} = invoke(args("-", output), Jason.encode!(intent(base)))
    assert stdout =~ "Payment authorization approved"
    refute stdout =~ "Consent URL"
    assert load(output)["response"]["access_token"]["value"] == "test-issued-secret"
    assert_three_requests()
  end

  test "generated nonces are fresh across independent starts", c do
    base = server(:pending)

    nonces =
      for index <- 1..2 do
        output = Path.join(c.directory, "session-#{index}.json")
        assert {_, "", 0} = invoke(args("-", output), Jason.encode!(intent(base)))
        assert_three_requests()
        load(output)["finish"]["nonce"]
      end

    assert length(Enum.uniq(nonces)) == 2
  end

  test "an explicit sender selects the payer without changing the signing client", c do
    base = server(:pending)
    output = Path.join(c.directory, "separate-sender.json")
    data = Map.put(intent(base), "sender", base <> "/receiver")
    assert {_, "", 0} = invoke(args("-", output), Jason.encode!(data))
    saved = load(output)
    assert saved["wallet_address"] == base <> "/sender"
    assert saved["payment"]["sender_wallet"]["id"] == base <> "/receiver-canonical"
    assert_received {:http_request, %{method: :GET, target: "/receiver"}}
    assert_received {:http_request, %{method: :GET, target: "/receiver"}}
    assert_received {:http_request, %{method: :POST, body: body} = wire}
    assert Jason.decode!(body)["client"] == base <> "/sender"
    assert valid_signature?(wire)
    refute_received {:http_request, _}
  end

  test "saved payment context survives verified grant continuation and supports grant cancellation",
       c do
    base =
      HTTPServer.start(fn wire ->
        case wire.target do
          "/sender" ->
            json(200, wallet(origin(wire), "sender"))

          "/receiver" ->
            json(200, wallet(origin(wire), "receiver"))

          "/issuer/receiver?part=a%2Bb" ->
            json(200, pending(origin(wire)))

          "/continue/receiver?step=a%2Bb" ->
            assert wire.headers["authorization"] == "GNAP test-continuation-secret"
            assert valid_signature?(wire)
            if wire.method == :DELETE, do: {204, [], ""}, else: json(200, approved(origin(wire)))
        end
      end)

    System.put_env("WALLET_ADDRESS", base <> "/sender")
    output = Path.join(c.directory, "session.json")
    assert {_, "", 0} = invoke(args("-", output), Jason.encode!(intent(base)))
    saved = load(output)
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
             invoke(["grant", "continue", output, "--callback-file", callback, "--allow-http"])

    assert load(output)["payment"] == saved["payment"]
    assert load(output)["callback_verified"]
    assert {_, "", 0} = invoke(["grant", "cancel", output, "--allow-http"])
    assert load(output)["state"] == "cancelled"
    refute Map.has_key?(load(output), "payment")
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :POST, target: "/issuer/receiver?part=a%2Bb"}}
    assert_received {:http_request, %{method: :POST, target: "/continue/receiver?step=a%2Bb"}}
    assert_received {:http_request, %{method: :DELETE, target: "/continue/receiver?step=a%2Bb"}}
    refute_receive {:http_request, _}, 20
  end

  test "unknown, missing and invalid intent fields fail before creating output or using HTTP",
       c do
    base = server(:pending)
    output = Path.join(c.directory, "session.json")

    for data <- [
          nil,
          [],
          %{},
          Map.delete(intent(base), "receiver"),
          Map.delete(intent(base), "receiveAmount"),
          Map.delete(intent(base), "finishUri"),
          Map.put(intent(base), "private-extra", "private-value"),
          Map.put(intent(base), "receiver", "$bad host"),
          Map.put(intent(base), "receiveAmount", nil),
          put_in(intent(base), ["receiveAmount", "value"], 1.5),
          Map.put(intent(base), "metadata", nil)
        ] do
      assert {"", stderr, 2} = invoke(args("-", output), Jason.encode!(data))
      refute stderr =~ "private-"
      refute File.exists?(output)
    end

    for input <- ["private-invalid-json", <<255>>] do
      assert {"", _, 2} = invoke(args("-", output), input)
    end

    assert {"", _, 2} = invoke(args(Path.join(c.directory, "private-missing-file"), output))
    refute_receive {:http_request, _}, 20
  end

  test "existing output, symlinks, missing parent and stale locks are never overwritten", c do
    base = server(:pending)
    output = Path.join(c.directory, "existing.json")
    File.write!(output, "private-original")
    File.chmod!(output, 0o644)
    assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
    assert File.read!(output) == "private-original"
    assert (File.stat!(output).mode &&& 0o777) == 0o644
    link = Path.join(c.directory, "link.json")
    File.ln_s!(output, link)
    assert {"", _, 1} = invoke(args("-", link), Jason.encode!(intent(base)))
    locked = Path.join(c.directory, "locked.json")
    File.write!(locked <> ".lock", "original-lock")
    assert {"", _, 1} = invoke(args("-", locked), Jason.encode!(intent(base)))
    assert File.read!(locked <> ".lock") == "original-lock"
    refute File.exists?(locked)

    assert {"", _, 1} =
             invoke(
               args("-", Path.join(c.directory, "missing/session.json")),
               Jason.encode!(intent(base))
             )

    refute_receive {:http_request, _}, 20
  end

  test "signing overrides select the payer client without replacing the receiver", c do
    base = server(:pending)
    output = Path.join(c.directory, "session.json")
    System.put_env("WALLET_ADDRESS", "invalid-wallet")
    System.put_env("KEY_ID", "invalid-id")
    System.put_env("PRIVATE_KEY_FILE", "missing-private-key")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-private-value")

    assert {_, "", 0} =
             invoke(
               args("-", output) ++
                 [
                   "--wallet-address",
                   base <> "/sender-override",
                   "--key-id",
                   "override-id",
                   "--key-file",
                   c.key
                 ],
               Jason.encode!(intent(base))
             )

    assert load(output)["wallet_address"] == base <> "/sender-override"
    assert_received {:http_request, %{target: "/sender-override"}}
    assert_received {:http_request, %{target: "/receiver"}}
    assert_received {:http_request, %{method: :POST, headers: headers, body: body}}
    assert headers["signature-input"] =~ ~s(keyid="override-id")
    assert Jason.decode!(body)["client"] == base <> "/sender-override"
    assert File.read!(c.key) == @pem
    refute_receive {:http_request, _}, 20
  end

  test "missing key settings and missing output fail safely before HTTP", c do
    base = server(:pending)
    output = Path.join(c.directory, "session.json")

    for name <- ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE) do
      previous = System.fetch_env!(name)
      System.delete_env(name)
      assert {"", _, 2} = invoke(args("-", output), Jason.encode!(intent(base)))
      System.put_env(name, previous)
    end

    for output <- ["", "-"] do
      assert {"", _, 2} = invoke(args("-", output), Jason.encode!(intent(base)))
    end

    assert {"", _, 2} = invoke(["payment", "start", "-"], Jason.encode!(intent(base)))
    refute_receive {:http_request, _}, 20
  end

  test "discovery errors remove the unused reservation without an authorization request", c do
    for response <- [{503, [], "private-server-body"}, {200, [], "private-invalid-json"}] do
      base = HTTPServer.start(response)
      System.put_env("WALLET_ADDRESS", base <> "/sender")
      output = Path.join(c.directory, "session.json")
      assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
      refute File.exists?(output)
      refute File.exists?(output <> ".lock")
      assert_received {:http_request, %{method: :GET}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "grant preflight failures clean up safely and ambiguous outcomes block replay", c do
    for response <- [
          {302, [{"Location", "https://auth.example/next"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {200, [], "{}"}
        ] do
      base = server(response)
      output = Path.join(c.directory, "session.json")
      assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
      assert load(output)["state"] == "uncertain"
      assert load(output)["attempt_operation"] == "payment-start"
      assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
      assert {"", _, 2} = invoke(["grant", "continue", output, "--allow-http"])
      assert_three_requests()
      File.rm!(output)
      stop_supervised!(Task)
    end

    base =
      HTTPServer.start(fn wire ->
        response =
          wallet(origin(wire), if(wire.target == "/sender", do: "sender", else: "receiver"))

        json(
          200,
          Map.put(response, "authServer", "https://user:private-password@auth.example/id")
        )
      end)

    System.put_env("WALLET_ADDRESS", base <> "/sender")
    output = Path.join(c.directory, "session.json")
    assert {"", _, 2} = invoke(args("-", output), Jason.encode!(intent(base)))
    refute File.exists?(output)
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "concurrent starts share the durable output lock", c do
    owner = self()

    base =
      server(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(200, pending(origin(wire))))
      end)

    output = Path.join(c.directory, "session.json")
    input = Path.join(c.directory, "request.json")
    File.write!(input, Jason.encode!(intent(base)))
    task = Task.async(fn -> PaymentStart.run(input, output: output, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    assert load(output)["state"] == "in-flight"
    assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
    send(server, :release)
    assert {:ok, %{status: "pending"}} = Task.await(task)
    assert_three_requests()
  end

  test "a killed start leaves its attempt and stale lock for reconciliation", c do
    owner = self()

    base =
      server(fn wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> json(200, pending(origin(wire))))
      end)

    output = Path.join(c.directory, "session.json")
    input = Path.join(c.directory, "request.json")
    File.write!(input, Jason.encode!(intent(base)))

    {pid, monitor} =
      spawn_monitor(fn -> PaymentStart.run(input, output: output, allow_http: true) end)

    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(output)["state"] == "in-flight"
    assert File.exists?(output <> ".lock")
    assert {"", _, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
    send(server, :release)
    assert_three_requests()
  end

  test "post-response write failure retains the recorded attempt and does not report success",
       c do
    parent = Path.join(c.directory, "private")
    moved = Path.join(c.directory, "moved")
    File.mkdir!(parent)
    output = Path.join(parent, "session.json")

    base =
      server(fn wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        json(200, approved(origin(wire)))
      end)

    assert {"", stderr, 1} = invoke(args("-", output), Jason.encode!(intent(base)))
    assert stderr =~ "Unable to save private grant session"
    assert load(Path.join(moved, "session.json"))["state"] == "in-flight"
    assert_three_requests()
  end

  test "unrelated flags are rejected and help does not initialize a payment" do
    for flags <- [
          ["extra"],
          ["--access-token-file", "private-token"],
          ["--callback-file", "private-callback"],
          ["--hash-encoding", "base64"],
          ["--first", "1"],
          ["--jwks"],
          ["--version"]
        ] do
      assert {"", _, 2} = invoke(["payment", "start", "-"] ++ flags)
    end

    assert {stdout, "", 0} = invoke(["payment", "start", "--help"])
    assert stdout =~ "payment start <file|->"
    refute_received {:http_request, _}
  end

  defp args(source, output), do: ["payment", "start", source, "--output", output, "--allow-http"]
  defp amount, do: %{"value" => "100", "assetCode" => "EUR", "assetScale" => 2}

  defp intent(base),
    do: %{
      "receiver" => base <> "/receiver",
      "receiveAmount" => amount(),
      "finishUri" => "https://client.example/return?state=local-state"
    }

  defp origin(wire), do: "http://" <> wire.headers["host"]
  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp pending(base),
    do: %{
      "continue" => continuation(base),
      "interact" => %{"redirect" => base <> "/consent/receiver", "finish" => "test-server-nonce"},
      "extension" => "test-issued-secret"
    }

  defp continuation(base),
    do: %{
      "uri" => base <> "/continue/receiver?step=a%2Bb",
      "access_token" => %{"value" => "test-continuation-secret"},
      "wait" => 0
    }

  defp approved(base),
    do: %{
      "continue" => continuation(base),
      "access_token" => %{
        "value" => "test-issued-secret",
        "manage" => base <> "/manage/receiver",
        "access" => []
      }
    }

  defp wallet(base, role),
    do: %{
      "id" => base <> "/#{role}-canonical",
      "assetCode" => if(role == "sender", do: "USD", else: "EUR"),
      "assetScale" => 2,
      "authServer" => base <> "/issuer/#{role}?part=a%2Bb",
      "resourceServer" => base <> "/payments/#{role}"
    }

  defp json(status, data), do: {status, [], Jason.encode!(data)}

  defp server(response) do
    base =
      HTTPServer.start(fn wire ->
        case {wire.method, wire.target} do
          {:GET, target} when target in ["/sender", "/sender-override"] ->
            json(200, wallet(origin(wire), "sender"))

          {:GET, "/receiver"} ->
            json(200, wallet(origin(wire), "receiver"))

          {:POST, "/issuer/receiver?part=a%2Bb"} ->
            cond do
              response == :pending -> json(200, pending(origin(wire)))
              response == :approved -> json(200, approved(origin(wire)))
              is_function(response, 1) -> response.(wire)
              true -> response
            end
        end
      end)

    System.put_env("WALLET_ADDRESS", base <> "/sender")
    base
  end

  defp assert_three_requests do
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :POST, target: "/issuer/receiver?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
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
