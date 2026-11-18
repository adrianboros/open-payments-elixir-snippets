defmodule OpenPaymentsSnippets.GrantContinueTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Bitwise
  alias OpenPaymentsSnippets.{CLI, GrantSession}
  alias OpenPaymentsSnippets.Commands.GrantContinuation
  alias OpenPaymentsSnippets.Test.HTTPServer

  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @finish %{
    "method" => "redirect",
    "uri" => "https://client.example/return?state=local-state",
    "nonce" => "VJLO6A4CATR0KRO"
  }
  @server_nonce "MBDOFXG4Y5CVJCX821LH"
  @reference "4IFWWIKYB2PQ6U56NL1"
  # Published GNAP hash vector, also verified independently by the SDK's Node fixture.
  @hash "x+gguKWTj8rQf7d7i3w3UhzvuJ5bpOlKyAlVpLxBffY="
  @hash_url "x-gguKWTj8rQf7d7i3w3UhzvuJ5bpOlKyAlVpLxBffY"
  @token %{
    "value" => "test-resource-secret",
    "manage" => "https://auth.example/token/id",
    "access" => []
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "open-payments-continue-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

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
    # These must not replace the recorded identity or continuation credential.
    System.put_env("WALLET_ADDRESS", "invalid-environment-wallet")
    System.put_env("KEY_ID", "invalid-environment-id")
    System.put_env("ACCESS_TOKEN", "wrong-resource-token")
    %{dir: dir, key: key, path: Path.join(dir, "session.json")}
  end

  test "verifies the published callback hash, signs once and saves private rotated credentials",
       c do
    path = c.path

    base =
      HTTPServer.start(fn wire ->
        assert load(path)["state"] == "in-flight"
        assert File.exists?(path <> ".lock")
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert valid_signature?(wire)
        {200, [], Jason.encode!(approved("https://auth.example/rotated"))}
      end)

    write(c.path, initial(base))
    cb = callback(c.dir)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--callback-file", cb, "--json"])
    assert Jason.decode!(stdout) == %{"status" => "approved", "saved" => true}

    assert_received {:http_request,
                     %{
                       method: :POST,
                       target: "/opaque%2fcontinue?part=a%2Bb",
                       headers: headers,
                       body: body
                     } = post}

    assert headers["authorization"] == "GNAP test-continuation-secret"
    assert Jason.decode!(body) == %{"interact_ref" => @reference}
    assert valid_signature?(post)
    refute valid_signature?(%{post | target: post.target <> "tampered"})
    result = load(c.path)
    assert result["kind"] == "grant-continuation"
    assert result["state"] == "ready"
    assert result["callback_verified"] == true
    assert result["response"]["continue"]["uri"] == "https://auth.example/rotated"
    assert result["response"]["continue"]["access_token"]["value"] == "test-rotated-secret"
    assert result["response"]["access_token"] == @token
    assert result["signing_jwk"]["kid"] == "test-key"
    refute File.read!(c.path) =~ "PRIVATE KEY"
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    refute File.exists?(c.path <> ".lock")
    refute Enum.any?(File.ls!(c.dir), &String.contains?(&1, ".tmp-"))
    refute_receive {:http_request, _}, 20
    before = File.read!(c.path)
    assert {"", stderr, 2} = invoke(args(c.path) ++ ["--callback-file", cb])
    assert stderr =~ "already been consumed"
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
  end

  test "explicit base64url and actual stdin callbacks work without encoding fallback", c do
    base = server(approved())
    write(c.path, initial(base))
    url = callback_url(@hash_url)
    assert {"", _, 2} = invoke(args(c.path) ++ ["--callback-file", "-"], url)
    refute_received {:http_request, _}

    assert {stdout, "", 0} =
             invoke(
               args(c.path) ++ ["--callback-file", "-", "--hash-encoding", "base64url"],
               url <> "\r\n"
             )

    assert stdout == "Grant approved\nGrant session updated.\n"
    assert_received {:http_request, %{method: :POST}}
  end

  test "rejects wrong callback destinations, errors, duplicates and double decoding before writing",
       c do
    base = server(approved())
    write(c.path, initial(base))
    original = File.read!(c.path)
    valid = callback_url()

    for url <- [
          String.replace(valid, "client.example", "other.example"),
          String.replace(valid, "/return?", "/other?"),
          String.replace(valid, "local-state", "other-state"),
          valid <> "&hash=duplicate",
          valid <> "&interact_ref=duplicate",
          valid <> "&error=denied",
          valid <> "&result=grant_rejected",
          valid <> "&unexpected=private",
          String.replace(valid, "%2B", "%252B"),
          String.replace(valid, "%2B", "+"),
          valid <> "#fragment",
          valid <> "&bad=%GG"
        ] do
      cb = callback(c.dir, url)
      assert {"", _, 2} = invoke(args(c.path) ++ ["--callback-file", cb])
      assert File.read!(c.path) == original
      refute File.exists?(c.path <> ".lock")
    end

    refute_receive {:http_request, _}, 20
  end

  test "binds hashes to the stored client nonce, server nonce and exact initial endpoint", c do
    base = server(approved())
    cb = callback(c.dir)

    for record <- [
          put_in(initial(base), ["finish", "nonce"], "changed-client-nonce"),
          put_in(initial(base), ["response", "interact", "finish"], "changed-server-nonce"),
          Map.put(initial(base), "grant_endpoint", "https://server.example.com/tx/")
        ] do
      write(c.path, record)
      before = File.read!(c.path)
      assert {"", _, 2} = invoke(args(c.path) ++ ["--callback-file", cb])
      assert File.read!(c.path) == before
    end

    refute_receive {:http_request, _}, 20
  end

  test "requires a callback only for initial sessions requesting a finish callback", c do
    base = server(approved())
    write(c.path, initial(base))
    assert {"", stderr, 2} = invoke(args(c.path))
    assert stderr =~ "Supply --callback-file"
    write(c.path, Map.put(initial(base), "finish", nil))
    assert {_, "", 0} = invoke(args(c.path))
    assert_received {:http_request, %{body: "", headers: headers}}
    assert headers["authorization"] == "GNAP test-continuation-secret"
    refute Map.has_key?(headers, "content-type")
    refute_receive {:http_request, _}, 20
  end

  test "honors wait intervals without sleeping, changing files or consuming callbacks", c do
    base = server(%{"continue" => continuation(base_placeholder(), 3600)})

    record =
      initial(base)
      |> put_in(["response", "continue", "wait"], 3600)
      |> Map.put("received_at", now())

    write(c.path, record)
    before = File.read!(c.path)
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    result = Jason.decode!(stdout)
    assert result["status"] == "waiting" and result["saved"] == false
    assert result["wait_seconds"] in 1..3600
    assert File.read!(c.path) == before
    refute_receive {:http_request, _}, 20
    write(c.path, record |> Map.put("received_at", past()) |> Map.put("finish", nil))
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout)["status"] == "pending"
    assert_received {:http_request, %{body: ""}}
    assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
    assert Jason.decode!(stdout)["status"] == "waiting"
    refute_receive {:http_request, _}, 20
  end

  test "uses rotated URI and continuation token on the next explicit bodyless call", c do
    base =
      HTTPServer.start(fn wire ->
        if wire.target == "/opaque%2fcontinue?part=a%2Bb" do
          base = "http://" <> wire.headers["host"]
          {200, [], Jason.encode!(%{"continue" => continuation(base <> "/rotated", 0)})}
        else
          assert wire.target == "/rotated"
          assert wire.headers["authorization"] == "GNAP test-rotated-secret"
          assert wire.body == ""
          {200, [], Jason.encode!(approved())}
        end
      end)

    write(c.path, initial(base))
    cb = callback(c.dir)
    assert {_, "", 0} = invoke(args(c.path) ++ ["--callback-file", cb])
    assert_received {:http_request, %{target: "/opaque%2fcontinue?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
    assert {_, "", 0} = invoke(args(c.path))
    assert_received {:http_request, %{target: "/rotated"}}
    refute_receive {:http_request, _}, 20
  end

  test "subject-only, combined and continuation-only results stay private", c do
    subject = %{"sub_ids" => [%{"format" => "uri", "id" => "test-subject-secret"}]}

    for {fields, status} <- [
          {%{"subject" => subject}, "subject"},
          {%{"subject" => subject, "access_token" => @token}, "approved"},
          {%{}, "pending"}
        ] do
      response = Map.merge(%{"continue" => continuation(base_placeholder(), 0)}, fields)
      base = server(response)
      write(c.path, Map.put(initial(base), "finish", nil))
      assert {stdout, "", 0} = invoke(args(c.path) ++ ["--json"])
      assert Jason.decode!(stdout) == %{"status" => status, "saved" => true}
      assert load(c.path)["response"] == response
      assert_received {:http_request, %{method: :POST, body: ""}}
      stop_supervised!(Task)
    end
  end

  test "rejects changed signing identities and a recorded mismatching public key", c do
    base = server(approved())
    write(c.path, initial(base))

    for options <- [
          ["--key-id", "other-id"],
          ["--wallet-address", "https://other.example/wallet"]
        ] do
      assert {"", _, 2} = invoke(args(c.path) ++ options)
    end

    write(c.path, Map.put(initial(base), "signing_jwk", %{"kid" => "wrong-key"}))
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "rejects malformed, future, unsupported and unavailable session states safely", c do
    base = server(approved())
    good = initial(base)

    for record <- [
          [],
          %{},
          Map.put(good, "version", 2),
          Map.put(good, "state", "in-flight"),
          Map.put(good, "state", "uncertain"),
          Map.put(good, "received_at", %{}),
          Map.put(
            good,
            "received_at",
            DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
          ),
          Map.put(good, "response", %{}),
          Map.put(good, "kind", "unknown"),
          Map.put(good, "callback_verified", "private-invalid")
        ] do
      write(c.path, record)
      assert {"", _, 2} = invoke(args(c.path))
    end

    File.write!(c.path, "private-invalid-json")
    assert {"", _, 2} = invoke(args(c.path))
    refute_receive {:http_request, _}, 20
  end

  test "requires private regular files and never follows symlinks or hard links", c do
    base = server(approved())
    write(c.path, initial(base))
    original = File.read!(c.path)
    File.chmod!(c.path, 0o644)
    assert {"", _, 2} = invoke(args(c.path))
    File.chmod!(c.path, 0o600)
    link = Path.join(c.dir, "symlink.json")
    File.ln_s!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    File.ln!(c.path, link)
    assert {"", _, 2} = invoke(args(link))
    File.rm!(link)
    assert File.read!(c.path) == original
    assert {"", _, 2} = invoke(args(Path.join(c.dir, "missing.json")))
    assert {"", _, 2} = invoke(["grant", "continue"])
    assert {"", _, 1} = invoke(args(Path.join(c.dir, "missing-parent/session.json")))
    refute_receive {:http_request, _}, 20
  end

  test "SDK preflight URL/token failures restore the session and make no request", c do
    base = server(approved())

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
      record = Map.put(record, "finish", nil)
      write(c.path, record)
      assert {"", _, 2} = invoke(["grant", "continue", c.path])
      assert load(c.path) == record
    end

    refute_receive {:http_request, _}, 20
  end

  test "HTTP, transport and response failures mark uncertain and block repeated requests", c do
    for response <- [
          {302, [{"Location", "https://auth.example/redirect"}], "private-body"},
          {503, [], "private-body"},
          :close,
          {200, [], "private-invalid-json"},
          {201, [], Jason.encode!(approved())},
          {200, [], "{}"}
        ] do
      base = HTTPServer.start(response)
      write(c.path, Map.put(initial(base), "finish", nil))
      assert {"", _, 1} = invoke(args(c.path))
      assert load(c.path)["state"] == "uncertain"
      assert_received {:http_request, %{method: :POST}}
      assert {"", _, 2} = invoke(args(c.path))
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "concurrent calls are locked until the first operation finishes", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:server_waiting, self()})

        receive do
          :release -> {200, [], Jason.encode!(approved())}
        end
      end)

    write(c.path, Map.put(initial(base), "finish", nil))
    task = Task.async(fn -> GrantContinuation.run(c.path, allow_http: true) end)
    assert_receive {:server_waiting, server_pid}, 2000
    assert load(c.path)["state"] == "in-flight"
    assert {"", stderr, 1} = invoke(args(c.path))
    assert stderr =~ "Unable to lock"
    send(server_pid, :release)
    assert {:ok, %{status: "approved"}} = Task.await(task)
    refute File.exists?(c.path <> ".lock")
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "a killed operation leaves a durable attempt and stale lock instead of replaying", c do
    owner = self()

    base =
      HTTPServer.start(fn _wire ->
        send(owner, {:server_waiting, self()})

        receive do
          :release -> {200, [], Jason.encode!(approved())}
        end
      end)

    write(c.path, Map.put(initial(base), "finish", nil))
    {pid, monitor} = spawn_monitor(fn -> GrantContinuation.run(c.path, allow_http: true) end)
    assert_receive {:server_waiting, server_pid}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert load(c.path)["state"] == "in-flight"
    assert File.exists?(c.path <> ".lock")
    assert {"", _, 1} = invoke(args(c.path))
    send(server_pid, :release)
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20
  end

  test "post-response save failure keeps the recorded attempt and never emits new credentials",
       c do
    parent = Path.join(c.dir, "private")
    moved = Path.join(c.dir, "moved")
    File.mkdir!(parent)
    path = Path.join(parent, "session.json")

    base =
      HTTPServer.start(fn _wire ->
        File.rename!(parent, moved)
        File.write!(parent, "blocking file")
        {200, [], Jason.encode!(approved())}
      end)

    write(path, Map.put(initial(base), "finish", nil))
    assert {"", stderr, 1} = invoke(args(path))
    assert stderr =~ "Unable to save private grant session"
    assert load(Path.join(moved, "session.json"))["state"] == "in-flight"
    assert_received {:http_request, %{method: :POST}}
    refute_receive {:http_request, _}, 20

    assert {:error, {:operation, _}} =
             GrantSession.save(Path.join(c.dir, "missing/session.json"), %{})
  end

  test "request-created sessions carry public signing context and resume without new discovery",
       c do
    base =
      HTTPServer.start(fn wire ->
        base = "http://" <> wire.headers["host"]

        case {wire.method, wire.target} do
          {:GET, "/wallet"} ->
            {200, [],
             Jason.encode!(%{
               "id" => base <> "/wallet",
               "assetCode" => "USD",
               "assetScale" => 2,
               "authServer" => base <> "/auth?part=a%2Bb",
               "resourceServer" => "https://payments.example/tenant"
             })}

          {:POST, "/auth?part=a%2Bb"} ->
            {200, [], Jason.encode!(initial(base)["response"])}

          {:POST, "/opaque%2fcontinue?part=a%2Bb"} ->
            {200, [], Jason.encode!(approved())}
        end
      end)

    payload = %{
      "client" => base <> "/wallet",
      "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]},
      "interact" => %{"start" => ["redirect"], "finish" => @finish}
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

    record = load(c.path)
    assert record["state"] == "ready" and record["callback_verified"] == false
    assert record["signing_jwk"]["kid"] == "test-key"

    digest =
      :crypto.hash(
        :sha256,
        Enum.join([@finish["nonce"], @server_nonce, @reference, record["grant_endpoint"]], "\n")
      )
      |> Base.encode64()

    cb = callback(c.dir, callback_url(digest))
    assert {_, "", 0} = invoke(args(c.path) ++ ["--callback-file", cb])
    assert_received {:http_request, %{method: :GET, target: "/wallet"}}
    assert_received {:http_request, %{method: :POST, target: "/auth?part=a%2Bb"}}
    assert_received {:http_request, %{method: :POST, target: "/opaque%2fcontinue?part=a%2Bb"}}
    refute_receive {:http_request, _}, 20
  end

  test "callback options and token roles remain strictly scoped", c do
    for args <- [
          ["grant", "continue", c.path, "extra"],
          ["grant", "continue", c.path, "--access-token-file", "private-file"],
          ["grant", "continue", c.path, "--output", "private-file"],
          [
            "grant",
            "continue",
            c.path,
            "--hash-encoding",
            "private-profile",
            "--callback-file",
            "private-file"
          ],
          ["grant", "continue", c.path, "--hash-encoding", "base64url"],
          ["grant", "continue", c.path, "--first", "1"],
          ["grant", "continue", c.path, "--version"],
          ["grant", "request", "-", "--callback-file", "private-file"],
          ["quote", "get", "https://payments.example/id", "--callback-file", "private-file"]
        ] do
      assert {"", _, 2} = invoke(args)
    end

    assert {stdout, "", 0} = invoke(["grant", "continue", "--help"])
    assert stdout =~ "grant continue <session>"
  end

  defp initial(base),
    do: %{
      "version" => 1,
      "kind" => "grant-request",
      "wallet_address" => "https://client.example/signer",
      "key_id" => "test-key",
      "grant_endpoint" => "https://server.example.com/tx",
      "received_at" => past(),
      "finish" => @finish,
      "response" => %{
        "continue" => %{
          "uri" => base <> "/opaque%2fcontinue?part=a%2Bb",
          "access_token" => %{"value" => "test-continuation-secret"},
          "wait" => 0
        },
        "interact" => %{"redirect" => "https://auth.example/consent", "finish" => @server_nonce}
      }
    }

  defp continuation(uri, wait),
    do: %{"uri" => uri, "access_token" => %{"value" => "test-rotated-secret"}, "wait" => wait}

  defp approved(uri \\ "https://auth.example/rotated"),
    do: %{"continue" => continuation(uri, 0), "access_token" => @token}

  defp base_placeholder, do: "https://auth.example/rotated"
  defp server(response), do: HTTPServer.start({200, [], Jason.encode!(response)})
  defp args(path), do: ["grant", "continue", path, "--allow-http"]
  defp past, do: DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.to_iso8601()
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp write(path, record) do
    File.write!(path, Jason.encode!(record))
    File.chmod!(path, 0o600)
  end

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp callback_url(hash \\ @hash),
    do: @finish["uri"] <> "&" <> URI.encode_query(%{"interact_ref" => @reference, "hash" => hash})

  defp callback(dir, url \\ callback_url()) do
    path = Path.join(dir, "callback.txt")
    File.write!(path, url <> "\n")
    path
  end

  defp valid_signature?(wire) do
    "sig1=" <> params = wire.headers["signature-input"]
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

    fields = [
      ~s("@method": #{wire.method}),
      ~s("@target-uri": http://#{wire.headers["host"]}#{wire.target}),
      ~s("authorization": #{wire.headers["authorization"]})
    ]

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

    base = Enum.join(fields ++ [~s("@signature-params": #{params})], "\n")
    public = Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)
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
          "test-rotated-secret",
          "test-resource-secret",
          "test-subject-secret",
          "private-body",
          "private-invalid-json",
          @reference,
          @hash,
          @server_nonce,
          "private-profile",
          "private-password"
        ] do
      refute stdout <> stderr =~ secret
    end

    {stdout, stderr, status}
  end
end
