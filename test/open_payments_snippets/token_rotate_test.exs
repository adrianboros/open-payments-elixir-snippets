defmodule OpenPaymentsSnippets.TokenRotateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.{GrantContinuation, TokenRotation}
  alias OpenPaymentsSnippets.Test.HTTPServer

  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """

  setup do
    dir =
      Path.join(System.tmp_dir!(), "open-payments-rotate-#{System.unique_integer([:positive])}")

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
    System.put_env("PRIVATE_KEY_FILE", key)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "wrong-env-id")
    System.put_env("ACCESS_TOKEN", "wrong-resource-token")
    %{dir: dir, key: key, path: Path.join(dir, "session.json")}
  end

  test "signs a bodyless management POST and saves the private SDK wrapper without resetting grant wait",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        assert load(path)["state"] == "in-flight"
        assert load(path)["attempt_operation"] == "token-rotate"
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(path <> ".lock").mode &&& 0o777) == 0o600
        assert valid_signature?(wire)
        base = "http://" <> wire.headers["host"]
        {200, [], Jason.encode!(rotated(base))}
      end)

    original = initial(base)
    write(c.path, original)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == %{"status" => "rotated", "saved" => true}

    assert_received {:http_request,
                     %{
                       method: :POST,
                       target: "/opaque%2fmanage?part=a%2Bb",
                       body: "",
                       headers: headers
                     } = wire}

    assert headers["authorization"] == "GNAP test-resource-secret"
    refute Map.has_key?(headers, "content-type")
    refute Map.has_key?(headers, "content-digest")
    assert valid_signature?(wire)
    refute valid_signature?(%{wire | method: :DELETE})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed"))
    saved = load(c.path)
    assert saved["state"] == "ready" and saved["kind"] == "grant-request"
    assert saved["response"]["access_token"] == rotated(base)["access_token"]
    assert saved["token_rotation_response"] == rotated(base)
    assert saved["response"]["continue"] == original["response"]["continue"]
    assert saved["response"]["subject"] == original["response"]["subject"]
    assert saved["response"]["private-extension"] == "test-response-extension-secret"
    assert saved["received_at"] == original["received_at"]
    assert saved["finish"] == original["finish"]
    assert {:ok, _, _} = DateTime.from_iso8601(saved["token_rotated_at"])
    assert saved["signing_jwk"]["kid"] == "test-key"
    refute File.read!(c.path) =~ "test-resource-secret"
    refute File.read!(c.path) =~ "PRIVATE KEY"
    refute Map.has_key?(saved, "attempted_at")
    refute Map.has_key?(saved, "attempt_operation")
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    refute Enum.any?(File.ls!(c.dir), &String.contains?(&1, ".tmp-"))
    refute File.exists?(c.path <> ".lock")
    refute_receive {:http_request, _}, 20
  end

  test "the next rotation uses the latest token and opaque management URI", c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        if wire.target == "/opaque%2fmanage?part=a%2Bb" do
          {200, [], Jason.encode!(rotated(base))}
        else
          assert wire.target == "/rotated%2fmanage?part=b%2Bc"
          assert wire.headers["authorization"] == "GNAP test-rotated-secret"
          assert valid_signature?(wire)

          {200, [],
           Jason.encode!(put_in(rotated(base), ["access_token", "value"], "test-newest-secret"))}
        end
      end)

    write(c.path, initial(base))
    assert {"Token rotated\nGrant session updated.\n", "", 0} = invoke(args(c.path))
    assert {_, "", 0} = invoke(args(c.path))
    assert load(c.path)["response"]["access_token"]["value"] == "test-newest-secret"
    refute File.read!(c.path) =~ "test-rotated-secret"
    assert_received {:http_request, %{target: "/opaque%2fmanage?part=a%2Bb"}}
    assert_received {:http_request, %{target: "/rotated%2fmanage?part=b%2Bc"}}
    refute_receive {:http_request, _}, 20
  end

  test "legacy and continued sessions rotate while pending and subject-only sessions are rejected",
       c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})
    good = initial(base)

    for record <- [Map.delete(good, "state"), Map.put(good, "kind", "grant-continuation")] do
      write(c.path, record)
      assert {_, "", 0} = invoke(args(c.path))
      assert_received {:http_request, %{method: :POST}}
    end

    pending =
      good
      |> update_in(["response"], &Map.delete(&1, "access_token"))
      |> put_in(["response", "interact"], %{
        "redirect" => "https://auth.example/consent",
        "finish" => "test-server-nonce"
      })

    subject_only =
      good
      |> Map.put("kind", "grant-continuation")
      |> update_in(["response"], &Map.delete(&1, "access_token"))

    for record <- [pending, subject_only] do
      write(c.path, record)
      before = File.read!(c.path)
      assert {"", stderr, 2} = invoke(args(c.path))
      assert stderr =~ "no issued access token"
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "continuation after rotation keeps its own credential and removes superseded rotation data",
       c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        if wire.target == "/opaque%2fmanage?part=a%2Bb" do
          {200, [], Jason.encode!(rotated(base))}
        else
          assert wire.target == "/continue"
          assert wire.headers["authorization"] == "GNAP test-continuation-secret"

          {200, [],
           Jason.encode!(%{
             "continue" => initial(base)["response"]["continue"],
             "access_token" => token(base, "test-newest-secret")
           })}
        end
      end)

    write(c.path, put_in(initial(base), ["response", "continue", "wait"], 0))
    assert {_, "", 0} = invoke(args(c.path))
    assert {:ok, %{status: "approved"}} = GrantContinuation.run(c.path, allow_http: true)
    saved = load(c.path)
    refute Map.has_key?(saved, "token_rotation_response")
    refute Map.has_key?(saved, "token_rotated_at")
    assert saved["response"]["access_token"]["value"] == "test-newest-secret"
    refute File.read!(c.path) =~ "test-rotated-secret"
    assert_received {:http_request, %{target: "/opaque%2fmanage?part=a%2Bb"}}
    assert_received {:http_request, %{target: "/continue"}}
    refute_receive {:http_request, _}, 20
  end

  test "identity/key mismatches and missing keys leave the session unchanged", c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})
    write(c.path, initial(base))
    before = File.read!(c.path)

    for flags <- [
          ["--key-id", "other"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", "missing-private-file"]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ flags)
      assert File.read!(c.path) == before
    end

    write(c.path, Map.put(initial(base), "signing_jwk", %{"kid" => "other"}))
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "explicit matching configuration overrides conflicting environment settings", c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})
    write(c.path, initial(base))
    System.put_env("PRIVATE_KEY_FILE", "missing-private-file")
    System.put_env("PRIVATE_KEY_BASE64", "conflicting-private-value")

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
  end

  test "SDK preflight URL and credential errors restore the original session", c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})

    for record <- [
          initial(base),
          put_in(
            initial(base),
            ["response", "access_token", "manage"],
            "https://user:private-password@auth.example/id"
          ),
          put_in(initial(base), ["response", "access_token", "value"], "private invalid token")
        ] do
      write(c.path, record)
      assert {"", _, 2} = invoke(["token", "rotate", c.path])
      assert load(c.path) == record
    end

    refute_receive {:http_request, _}, 20
  end

  test "bad session state, malformed data and invalid token schemas fail before HTTP", c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})
    good = initial(base)

    for record <- [
          %{},
          Map.put(good, "version", 2),
          Map.put(good, "state", "cancelled"),
          Map.put(good, "state", "uncertain"),
          Map.put(good, "state", "in-flight"),
          Map.put(good, "received_at", "private-invalid-time"),
          put_in(good, ["response", "access_token"], %{"value" => "test-continuation-secret"})
        ] do
      write(c.path, record)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path))
      assert File.read!(c.path) == before
    end

    File.write!(c.path, "private-invalid-json")
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "only private single-link files are accepted and stale locks are preserved", c do
    base = HTTPServer.start({200, [], Jason.encode!(rotated())})
    write(c.path, initial(base))
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path))
    File.chmod!(c.path, 0o600)
    link = Path.join(c.dir, "link.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.write!(c.path <> ".lock", "existing")
    assert {"", _, 1} = invoke(args(c.path))
    assert File.read!(c.path <> ".lock") == "existing"
    assert {"", _, 2} = invoke(args(Path.join(c.dir, "missing.json")))
    refute_receive {:http_request, _}, 20
  end

  test "ambiguous failures block rotation, continuation and cancellation without retry", c do
    for response <- [
          {302, [{"Location", "https://auth.example/redirect"}], "private-server-body"},
          {503, [], "private-server-body"},
          :close,
          {201, [], "{}"},
          {200, [], "private-invalid-json"},
          {200, [], "{}"},
          {200, [], Jason.encode!(%{"access_token" => %{"value" => "test-newest-secret"}})}
        ] do
      base = HTTPServer.start(response)
      write(c.path, initial(base))
      assert {"", _, 1} = invoke(args(c.path))
      assert load(c.path)["state"] == "uncertain"
      assert load(c.path)["attempt_operation"] == "token-rotate"
      assert_received {:http_request, %{method: :POST}}

      for argv <- [
            args(c.path),
            ["grant", "continue", c.path, "--allow-http"],
            ["grant", "cancel", c.path, "--allow-http"]
          ] do
        assert {"", _, 2} = invoke(argv)
      end

      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "rotation shares the grant lock with concurrent token and grant operations", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> {200, [], Jason.encode!(rotated())})
      end)

    write(c.path, initial(base))
    task = Task.async(fn -> TokenRotation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000

    for argv <- [
          args(c.path),
          ["grant", "continue", c.path, "--allow-http"],
          ["grant", "cancel", c.path, "--allow-http"]
        ] do
      assert {"", _, 1} = invoke(argv)
    end

    send(server, :release)
    assert {:ok, %{status: "rotated"}} = Task.await(task)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed rotation retains its durable attempt and lock", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> {200, [], Jason.encode!(rotated())})
      end)

    write(c.path, initial(base))
    {pid, monitor} = spawn_monitor(fn -> TokenRotation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(c.path)["state"] == "in-flight"
    assert load(c.path)["attempt_operation"] == "token-rotate"
    assert File.exists?(c.path <> ".lock")
    assert {"", _, 1} = invoke(args(c.path))
    send(server, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "post-response write failure retains the old attempt and never prints new credentials",
       c do
    parent = Path.join(c.dir, "private")
    moved = Path.join(c.dir, "moved")
    File.mkdir!(parent)
    path = Path.join(parent, "session.json")

    base =
      HTTPServer.start(fn _wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        {200, [], Jason.encode!(rotated())}
      end)

    write(path, initial(base))
    assert {"", stderr, 1} = invoke(args(path))
    assert stderr =~ "Unable to save private grant session"
    assert load(Path.join(moved, "session.json"))["state"] == "in-flight"

    assert load(Path.join(moved, "session.json"))["response"]["access_token"]["value"] ==
             "test-resource-secret"

    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "request-created approved grants can rotate without another wallet discovery", c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        case wire.target do
          "/wallet" ->
            {200, [],
             Jason.encode!(%{
               "id" => base <> "/wallet",
               "assetCode" => "USD",
               "assetScale" => 2,
               "authServer" => base <> "/auth",
               "resourceServer" => "https://payments.example"
             })}

          "/auth" ->
            {200, [], Jason.encode!(initial(base)["response"])}

          "/opaque%2fmanage?part=a%2Bb" ->
            {200, [], Jason.encode!(rotated(base))}
        end
      end)

    payload = %{
      "client" => base <> "/wallet",
      "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]}
    }

    assert {_, "", 0} =
             invoke(
               [
                 "grant",
                 "request",
                 "-",
                 "--output",
                 c.path,
                 "--wallet-address",
                 base <> "/wallet",
                 "--key-id",
                 "test-key",
                 "--allow-http"
               ],
               Jason.encode!(payload)
             )

    assert {_, "", 0} = invoke(args(c.path))
    assert_received {:http_request, %{method: :GET, target: "/wallet"}}
    assert_received {:http_request, %{method: :POST, target: "/auth"}}
    assert_received {:http_request, %{method: :POST, target: "/opaque%2fmanage?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
  end

  test "missing sessions and unrelated options fail while token rotation help is available", c do
    for argv <- [
          ["token", "rotate"],
          args(c.path) ++ ["extra"],
          args(c.path) ++ ["--access-token-file", "private-token"],
          args(c.path) ++ ["--output", "private-output"],
          args(c.path) ++ ["--callback-file", "private-callback"],
          args(c.path) ++ ["--hash-encoding", "base64"],
          args(c.path) ++ ["--first", "1"],
          args(c.path) ++ ["--jwks"],
          args(c.path) ++ ["--version"]
        ] do
      assert {"", _, 2} = invoke(argv)
    end

    assert {stdout, "", 0} = invoke(["token", "rotate", "--help"])
    assert stdout =~ "token rotate <session>"
  end

  defp initial(base),
    do: %{
      "version" => 1,
      "kind" => "grant-request",
      "state" => "ready",
      "wallet_address" => "https://client.example/signer",
      "key_id" => "test-key",
      "grant_endpoint" => "https://auth.example/initial",
      "received_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "finish" => %{
        "method" => "redirect",
        "uri" => "https://client.example/return",
        "nonce" => "test-client-nonce"
      },
      "response" => %{
        "continue" => %{
          "uri" => base <> "/continue",
          "access_token" => %{"value" => "test-continuation-secret"},
          "wait" => 3600
        },
        "access_token" => token(base, "test-resource-secret"),
        "subject" => %{"sub_ids" => [%{"format" => "uri", "id" => "test-subject-secret"}]},
        "private-extension" => "test-response-extension-secret"
      }
    }

  defp token(base, value),
    do: %{
      "value" => value,
      "manage" => base <> "/opaque%2fmanage?part=a%2Bb",
      "access" => [%{"type" => "quote", "actions" => ["create"]}],
      "expires_in" => -1
    }

  defp rotated(base \\ "https://auth.example"),
    do: %{
      "access_token" =>
        token(base, "test-rotated-secret")
        |> Map.put("manage", base <> "/rotated%2fmanage?part=b%2Bc"),
      "private-extension" => "test-rotation-extension-secret"
    }

  defp args(path), do: ["token", "rotate", path, "--allow-http"]
  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp write(path, session) do
    File.write!(path, Jason.encode!(session))
    File.chmod!(path, 0o600)
  end

  defp valid_signature?(wire) do
    "sig1=" <> params = wire.headers["signature-input"]
    [_, signature] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

    message =
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
    :crypto.verify(:eddsa, :none, message, Base.decode64!(signature), [public, :ed25519])
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
          "test-resource-secret",
          "test-continuation-secret",
          "test-rotated-secret",
          "test-newest-secret",
          "test-subject-secret",
          "test-response-extension-secret",
          "test-rotation-extension-secret",
          "test-client-nonce",
          "private-server-body",
          "private-invalid-json",
          "private-password",
          "missing-private-file",
          "conflicting-private-value"
        ] do
      refute stdout <> stderr =~ secret
    end

    {stdout, stderr, status}
  end
end
