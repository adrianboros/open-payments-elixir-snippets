defmodule OpenPaymentsSnippets.GrantCancelTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Commands.{GrantCancellation, GrantContinuation}
  alias OpenPaymentsSnippets.Test.HTTPServer

  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @token %{
    "value" => "test-resource-secret",
    "manage" => "https://auth.example/manage",
    "access" => []
  }

  setup do
    dir =
      Path.join(System.tmp_dir!(), "open-payments-cancel-#{System.unique_integer([:positive])}")

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

  test "signs one bodyless DELETE despite pending consent and wait, then removes private results",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        assert load(path)["state"] == "in-flight"
        assert load(path)["attempt_operation"] == "cancel"
        assert File.exists?(path <> ".lock")
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert valid_signature?(wire)
        # The SDK's 204 contract deliberately ignores content coding and body.
        {204, [{"Content-Encoding", "gzip"}], "private-server-body"}
      end)

    write(c.path, initial(base))
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout) == %{"status" => "cancelled", "saved" => true}

    assert_received {:http_request,
                     %{
                       method: :DELETE,
                       target: "/opaque%2fcancel?part=a%2Bb",
                       body: "",
                       headers: headers
                     } = wire}

    assert headers["authorization"] == "GNAP test-continuation-secret"
    refute Map.has_key?(headers, "content-type")
    refute Map.has_key?(headers, "content-digest")
    assert valid_signature?(wire)
    refute valid_signature?(%{wire | method: :POST})
    refute valid_signature?(%{wire | target: wire.target <> "changed"})
    refute valid_signature?(put_in(wire.headers["authorization"], "GNAP changed"))
    cancelled = load(c.path)
    assert cancelled["kind"] == "grant-cancellation" and cancelled["state"] == "cancelled"
    assert {:ok, _, _} = DateTime.from_iso8601(cancelled["cancelled_at"])
    assert cancelled["wallet_address"] == "https://client.example/signer"
    assert cancelled["signing_jwk"]["kid"] == "test-key"

    assert Enum.sort(Map.keys(cancelled)) ==
             ~w(cancelled_at grant_endpoint key_id kind signing_jwk state version wallet_address)

    refute File.read!(c.path) =~ "secret"
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.dir), &String.contains?(&1, ".tmp-"))
    assert {"", _, 2} = invoke(args(c.path))
    assert {"", _, 2} = invoke(["grant", "continue", c.path, "--allow-http"])
    assert load(c.path) == cancelled
    refute_receive {:http_request, _}, 20
  end

  test "accepts legacy initial approval and latest continuation sessions", c do
    base = HTTPServer.start({204, [], ""})
    initial = initial(base)

    approved =
      initial
      |> Map.delete("state")
      |> Map.delete("callback_verified")
      |> put_in(["response"], %{
        "continue" => initial["response"]["continue"],
        "access_token" => @token
      })

    continued =
      approved
      |> Map.put("kind", "grant-continuation")
      |> put_in(["response", "subject"], %{
        "sub_ids" => [%{"format" => "uri", "id" => "test-subject-secret"}]
      })

    for record <- [approved, continued] do
      write(c.path, record)
      assert {"Grant cancelled\nGrant session updated.\n", "", 0} = invoke(args(c.path))
      assert_received {:http_request, %{method: :DELETE}}
    end

    refute_receive {:http_request, _}, 20
  end

  test "continuation then cancellation uses the rotated URI and credential", c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        case wire.method do
          :POST ->
            {200, [],
             Jason.encode!(%{
               "continue" =>
                 continuation(base <> "/rotated%2fgrant?part=b%2Bc", "test-rotated-secret")
             })}

          :DELETE ->
            assert wire.target == "/rotated%2fgrant?part=b%2Bc"
            assert wire.headers["authorization"] == "GNAP test-rotated-secret"
            assert valid_signature?(wire)
            {204, [], ""}
        end
      end)

    record =
      initial(base) |> Map.put("finish", nil) |> put_in(["response", "continue", "wait"], 0)

    write(c.path, record)
    assert {:ok, %{status: "pending"}} = GrantContinuation.run(c.path, allow_http: true)
    assert {_, "", 0} = invoke(args(c.path))
    assert_received {:http_request, %{method: :POST}}
    assert_received {:http_request, %{method: :DELETE}}
    refute_receive {:http_request, _}, 20
  end

  test "rejects signing identity or public-key changes before modifying the session", c do
    base = HTTPServer.start({204, [], ""})
    write(c.path, initial(base))
    before = File.read!(c.path)

    for options <- [
          ["--key-id", "other-id"],
          ["--wallet-address", "https://other.example/wallet"],
          ["--key-file", Path.join(c.dir, "missing-private-file")]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ options)
      assert File.read!(c.path) == before
    end

    write(c.path, Map.put(initial(base), "signing_jwk", %{"kid" => "wrong-key"}))
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "explicit matching identity and key-file override conflicting key environment", c do
    base = HTTPServer.start({204, [], ""})
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

    assert_received {:http_request, %{method: :DELETE}}
  end

  test "SDK preflight rejects HTTP policy, unsafe URLs and malformed tokens without a request",
       c do
    base = HTTPServer.start({204, [], ""})

    for record <- [
          initial(base),
          put_in(
            initial(base),
            ["response", "continue", "uri"],
            "https://user:private-password@auth.example/id"
          ),
          put_in(
            initial(base),
            ["response", "continue", "access_token", "value"],
            "private invalid token"
          )
        ] do
      write(c.path, record)
      assert {"", _, 2} = invoke(["grant", "cancel", c.path])
      assert load(c.path) == record
    end

    refute_receive {:http_request, _}, 20
  end

  test "unsupported, malformed and interrupted sessions never reach HTTP", c do
    base = HTTPServer.start({204, [], ""})
    good = initial(base)

    for record <- [
          %{},
          [],
          Map.put(good, "version", 2),
          Map.put(good, "state", "in-flight"),
          Map.put(good, "state", "uncertain"),
          Map.put(good, "state", "cancelled"),
          Map.put(good, "response", %{}),
          Map.put(good, "kind", "unknown"),
          Map.put(good, "received_at", "private-invalid-time")
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

  test "requires a private single-link regular session and honors existing locks", c do
    base = HTTPServer.start({204, [], ""})
    write(c.path, initial(base))
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path))
    File.chmod!(c.path, 0o600)
    link = Path.join(c.dir, "linked.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.write!(c.path <> ".lock", "existing lock")
    assert {"", _, 1} = invoke(args(c.path))
    assert File.read!(c.path <> ".lock") == "existing lock"
    assert {"", _, 2} = invoke(args(Path.join(c.dir, "missing.json")))
    assert {"", _, 1} = invoke(args(Path.join(c.dir, "missing-parent/session.json")))
    refute_receive {:http_request, _}, 20
  end

  test "HTTP, unexpected success and transport failures block another cancellation or continuation",
       c do
    for response <- [
          {200, [], "{}"},
          {201, [], ""},
          {302, [{"Location", "https://auth.example/redirect"}], "private-server-body"},
          {401, [], "private-server-body"},
          {503, [], "private-server-body"},
          :close
        ] do
      base = HTTPServer.start(response)
      write(c.path, initial(base))
      assert {"", _, 1} = invoke(args(c.path))
      assert load(c.path)["state"] == "uncertain"
      assert load(c.path)["attempt_operation"] == "cancel"
      assert_received {:http_request, %{method: :DELETE}}
      assert {"", _, 2} = invoke(args(c.path))
      assert {"", _, 2} = invoke(["grant", "continue", c.path, "--allow-http"])
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "cancellation and continuation share the same exclusive lock", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> {204, [], ""})
      end)

    write(c.path, initial(base))
    task = Task.async(fn -> GrantCancellation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    assert {"", _, 1} = invoke(args(c.path))
    assert {"", _, 1} = invoke(["grant", "continue", c.path, "--allow-http"])
    send(server, :release)
    assert {:ok, %{status: "cancelled"}} = Task.await(task)
    assert_received {:http_request, %{method: :DELETE}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed cancellation retains an in-flight marker and stale lock", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:waiting, self()})
        receive do: (:release -> {204, [], ""})
      end)

    write(c.path, initial(base))
    {pid, monitor} = spawn_monitor(fn -> GrantCancellation.run(c.path, allow_http: true) end)
    assert_receive {:waiting, server}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(c.path)["state"] == "in-flight"
    assert load(c.path)["attempt_operation"] == "cancel"
    assert File.exists?(c.path <> ".lock")
    assert {"", _, 1} = invoke(args(c.path))
    send(server, :release)
    assert_received {:http_request, %{method: :DELETE}}
    refute_receive {:http_request, _}, 20
  end

  test "post-response file failure reports failure and retains the recorded cancellation attempt",
       c do
    parent = Path.join(c.dir, "private")
    moved = Path.join(c.dir, "moved")
    File.mkdir!(parent)
    path = Path.join(parent, "session.json")

    base =
      HTTPServer.start(fn _wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        {204, [], ""}
      end)

    write(path, initial(base))
    assert {"", stderr, 1} = invoke(args(path))
    assert stderr =~ "Unable to save private grant session"
    assert load(Path.join(moved, "session.json"))["state"] == "in-flight"
    assert_received {:http_request, %{method: :DELETE}}
    refute_receive {:http_request, _}, 20
  end

  test "request-created sessions cancel without further discovery or a callback", c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        case wire.method do
          :GET ->
            {200, [],
             Jason.encode!(%{
               "id" => base <> "/wallet",
               "assetCode" => "USD",
               "assetScale" => 2,
               "authServer" => base <> "/auth",
               "resourceServer" => "https://payments.example"
             })}

          :POST ->
            {200, [], Jason.encode!(initial(base)["response"])}

          :DELETE ->
            {204, [], ""}
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
    assert_received {:http_request, %{method: :DELETE, target: "/opaque%2fcancel?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
  end

  test "rejects unrelated flags and missing sessions while exposing help", c do
    for argv <- [
          ["grant", "cancel"],
          args(c.path) ++ ["extra"],
          args(c.path) ++ ["--callback-file", "private-file"],
          args(c.path) ++ ["--hash-encoding", "base64"],
          args(c.path) ++ ["--output", "private-file"],
          args(c.path) ++ ["--access-token-file", "private-file"],
          args(c.path) ++ ["--first", "1"],
          args(c.path) ++ ["--jwks"],
          args(c.path) ++ ["--version"]
        ] do
      assert {"", _, 2} = invoke(argv)
    end

    assert {stdout, "", 0} = invoke(["grant", "cancel", "--help"])
    assert stdout =~ "grant cancel <session>"
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
      "callback_verified" => false,
      "finish" => %{
        "method" => "redirect",
        "uri" => "https://client.example/return",
        "nonce" => "test-client-nonce"
      },
      "response" => %{
        "continue" =>
          continuation(base <> "/opaque%2fcancel?part=a%2Bb", "test-continuation-secret"),
        "interact" => %{
          "redirect" => "https://auth.example/consent",
          "finish" => "test-server-nonce"
        }
      },
      "private-extension" => "test-private-extension-secret"
    }

  defp continuation(uri, token),
    do: %{"uri" => uri, "access_token" => %{"value" => token}, "wait" => 3600}

  defp args(path), do: ["grant", "cancel", path, "--allow-http"]
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
          "test-continuation-secret",
          "test-rotated-secret",
          "test-resource-secret",
          "test-subject-secret",
          "test-private-extension-secret",
          "test-client-nonce",
          "test-server-nonce",
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
