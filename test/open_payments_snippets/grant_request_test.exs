defmodule OpenPaymentsSnippets.GrantRequestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Bitwise

  alias OpenPaymentsSnippets.CLI
  alias OpenPaymentsSnippets.Test.HTTPServer

  # Public RFC 8032 test vector 1, also used by the key command tests.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """
  @payload %{
    "client" => "https://wallet.example/alice",
    "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]}
  }
  @continuation %{
    "uri" => "https://auth.example/continue/opaque",
    "access_token" => %{"value" => "test-continuation-secret"},
    "wait" => 5
  }
  @pending %{
    "continue" => @continuation,
    "interact" => %{
      "redirect" => "https://auth.example/consent/id",
      "finish" => "test-server-nonce"
    },
    "custom" => %{"secret" => "test-extension-secret"}
  }
  @approved %{
    "continue" => @continuation,
    "access_token" => %{
      "value" => "test-resource-secret",
      "manage" => "https://auth.example/token/id",
      "access" => []
    }
  }
  @auth_path "/tenant/opaque%2fpath/auth?part=a%2Bb&part=second"

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-grant-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    names = ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 PRIVATE_KEY)
    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    key = Path.join(directory, "public-test-key.pem")
    File.write!(key, @pem)
    System.put_env("KEY_ID", "test-key")
    System.put_env("PRIVATE_KEY_FILE", key)
    %{output: Path.join(directory, "grant.json"), key: key, tmp_dir: directory}
  end

  test "discovers unsigned then sends one signed POST and saves pending callback state", %{
    output: output
  } do
    base = server(@pending)
    System.put_env("WALLET_ADDRESS", base <> "/wallet")

    finish = %{
      "method" => "redirect",
      "uri" => "https://client.example/return",
      "nonce" => "test-client-nonce"
    }

    payload = Map.put(@payload, "interact", %{"start" => ["redirect"], "finish" => finish})

    assert {stdout, "", 0} = invoke(arguments(output), Jason.encode!(payload))
    assert stdout == "Grant pending\nGrant session saved to the requested private file.\n"
    refute stdout =~ "secret"
    refute stdout =~ "nonce"
    assert_received {:http_request, %{method: :GET, target: "/wallet", headers: get_headers}}
    refute Map.has_key?(get_headers, "signature")
    assert_received {:http_request, %{method: :POST, target: @auth_path} = post}
    assert Jason.decode!(post.body) == payload
    assert post.headers["signature-input"] =~ ~s(keyid="test-key")
    assert post.headers["signature"] != ""
    assert valid_signature?(post)
    refute valid_signature?(%{post | target: post.target <> "tampered"})
    refute Map.has_key?(post.headers, "authorization")

    assert post.headers["content-digest"] ==
             "sha-512=:#{Base.encode64(:crypto.hash(:sha512, post.body))}:"

    refute_receive {:http_request, _}, 20

    assert {:ok, stat} = File.stat(output)
    assert (stat.mode &&& 0o777) == 0o600
    session = output |> File.read!() |> Jason.decode!()
    assert session["version"] == 1
    assert session["kind"] == "grant-request"
    assert session["wallet_address"] == base <> "/wallet"
    assert session["key_id"] == "test-key"
    assert session["grant_endpoint"] == base <> @auth_path
    assert session["finish"] == finish
    assert {:ok, _, _} = DateTime.from_iso8601(session["received_at"])
    assert session["response"] == @pending
    refute Map.has_key?(session, "request")
    refute File.read!(output) =~ "PRIVATE KEY"
  end

  test "JSON summary omits credentials and saves immediately approved response", %{
    output: output,
    key: key
  } do
    base = server(@approved)
    System.put_env("WALLET_ADDRESS", "invalid-env-wallet")
    System.put_env("KEY_ID", "invalid-env-id")
    System.put_env("PRIVATE_KEY_FILE", "/missing-env-key")
    System.put_env("PRIVATE_KEY_BASE64", "invalid-conflicting-env-source")

    args =
      arguments(output) ++
        [
          "--json",
          "--wallet-address",
          base <> "/wallet",
          "--key-file",
          key,
          "--key-id",
          "override-id"
        ]

    assert {stdout, "", 0} = invoke(args, Jason.encode!(@payload))
    assert Jason.decode!(stdout) == %{"status" => "approved", "saved" => true}
    session = output |> File.read!() |> Jason.decode!()
    assert session["response"] == @approved
    assert session["key_id"] == "override-id"
    assert session["finish"] == nil
    assert_received {:http_request, %{method: :GET}}
    assert_received {:http_request, %{method: :POST, headers: headers}}
    assert headers["signature-input"] =~ ~s(keyid="override-id")
  end

  test "reads JSON files and exported base64 PEM settings", %{output: output, tmp_dir: directory} do
    base = server(@approved)
    System.put_env("WALLET_ADDRESS", base <> "/wallet")
    System.delete_env("PRIVATE_KEY_FILE")
    System.put_env("PRIVATE_KEY_BASE64", Base.encode64(@pem))
    source = Path.join(directory, "request.json")
    File.write!(source, Jason.encode!(@payload))
    assert {_, "", 0} = invoke(["grant", "request", source, "--output", output, "--allow-http"])
    assert File.read!(source) == Jason.encode!(@payload)
    assert File.exists?(output)
  end

  test "requires an explicit secret destination and complete source before networking", %{
    output: output
  } do
    for args <- [
          ["grant", "request", "-"],
          ["grant", "request", "-", "--output", "-"],
          ["grant", "request", "-", "--output", ""]
        ] do
      assert {"", stderr, 2} = invoke(args)
      assert stderr =~ "Supply --output"
    end

    for {source, input} <- [
          {nil, ""},
          {"-", "not-json-private"},
          {"-", "{}"},
          {"/missing-private-file", ""},
          {"-", Jason.encode!(Map.delete(@payload, "client"))}
        ] do
      args = ["grant", "request"] ++ if(source, do: [source], else: [])
      assert {"", stderr, 2} = invoke(args ++ ["--output", output], input)
      refute stderr =~ "not-json-private"
      refute stderr =~ "/missing-private-file"
      refute File.exists?(output)
    end

    refute_received {:http_request, _}
  end

  test "checks missing and invalid signing and wallet configuration offline", %{output: output} do
    for {name, value} <- [
          {"KEY_ID", ""},
          {"PRIVATE_KEY_FILE", "/private-missing.pem"},
          {"WALLET_ADDRESS", "http://localhost:3000/wallet"}
        ] do
      original = System.get_env(name)
      System.put_env(name, value)

      assert {"", stderr, 2} =
               invoke(["grant", "request", "-", "--output", output], Jason.encode!(@payload))

      refute stderr =~ "/private-missing.pem"
      if original, do: System.put_env(name, original), else: System.delete_env(name)
      refute File.exists?(output)
    end

    assert {"", stderr, 2} =
             invoke(["grant", "request", "-", "--output", output], Jason.encode!(@payload))

    assert stderr =~ "Supply --wallet-address or set WALLET_ADDRESS."
    refute_received {:http_request, _}
  end

  test "refuses existing files, symlinks, and unwritable destinations before discovery", %{
    output: output,
    key: key,
    tmp_dir: directory
  } do
    System.put_env("WALLET_ADDRESS", "https://wallet.example/alice")
    File.write!(output, "existing-private-state")
    link = Path.join(directory, "link.json")
    File.ln_s!(key, link)

    for destination <- [
          output,
          key,
          link,
          directory,
          Path.join(directory, "missing/session.json")
        ] do
      assert {"", stderr, 1} =
               invoke(["grant", "request", "-", "--output", destination], Jason.encode!(@payload))

      assert stderr =~ "Unable to create grant-session file."
    end

    assert File.read!(output) == "existing-private-state"
    assert File.read!(key) == @pem
    refute_received {:http_request, _}
  end

  test "removes new output after discovery failure without leaking server data", %{output: output} do
    base = HTTPServer.start({401, [], ~s({"error":"test-secret-error"})})
    System.put_env("WALLET_ADDRESS", base <> "/wallet")
    assert {"", stderr, 1} = invoke(arguments(output), Jason.encode!(@payload))
    assert stderr =~ "HTTP 401"
    refute stderr =~ "test-secret-error"
    refute File.exists?(output)
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "keeps returned authorization endpoints under SDK URL policy", %{output: output} do
    base = server(@pending, "https://user:private-password@auth.example/tenant")
    System.put_env("WALLET_ADDRESS", base <> "/wallet")
    assert {"", stderr, 2} = invoke(arguments(output), Jason.encode!(@payload))
    refute stderr =~ "private-password"
    refute File.exists?(output)
    assert_received {:http_request, %{method: :GET}}
    refute_receive {:http_request, _}, 20
  end

  test "does not redirect, retry, or echo error bodies after grant HTTP failures", %{
    output: output
  } do
    for status <- [302, 400, 503] do
      base =
        server(
          {status, [{"Location", "https://auth.example/private"}], "test-private-error-body"}
        )

      System.put_env("WALLET_ADDRESS", base <> "/wallet")
      assert {"", stderr, 1} = invoke(arguments(output), Jason.encode!(@payload))
      assert stderr =~ "HTTP #{status}"
      refute stderr =~ "test-private-error-body"
      refute File.exists?(output)
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "reports ambiguous transport and response failures without retrying", %{output: output} do
    for response <- [
          :close,
          {200, [], "test-private-invalid-json"},
          {200, [], "{}"},
          {201, [], Jason.encode!(@approved)}
        ] do
      base = server(response)
      System.put_env("WALLET_ADDRESS", base <> "/wallet")
      assert {"", stderr, 1} = invoke(arguments(output), Jason.encode!(@payload))
      assert stderr =~ "No automatic retry was made; the grant may have been created."
      refute stderr =~ "test-private-invalid-json"
      refute File.exists?(output)
      assert_received {:http_request, %{method: :GET}}
      assert_received {:http_request, %{method: :POST}}
      refute_receive {:http_request, _}, 20
      stop_supervised!(Task)
    end
  end

  test "scopes options and rejects extra arguments before networking", %{output: output} do
    for args <- [
          ["grant", "request", "-", "extra", "--output", output],
          ["grant", "request", "-", "--output", output, "--jwks"],
          ["grant", "request", "-", "--version"],
          ["grant", "validate", "-", "--output", output],
          ["keys", "validate", "--wallet-address", "https://wallet.example/alice"],
          ["wallet", "get", "--output", output]
        ] do
      assert {"", _stderr, 2} = invoke(args)
    end

    assert {stdout, "", 0} = invoke(["grant", "request", "--help"])
    assert stdout =~ "grant request <file|->"
    refute File.exists?(output)
    refute_received {:http_request, _}
  end

  defp arguments(output), do: ["grant", "request", "-", "--output", output, "--allow-http"]

  # Verify the real wire with the public RFC key, independently of SDK signing helpers.
  defp valid_signature?(wire) do
    "sig1=" <> params = wire.headers["signature-input"]
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, wire.headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{wire.headers["host"]}#{wire.target}),
          ~s("content-digest": #{wire.headers["content-digest"]}),
          ~s("content-length": #{wire.headers["content-length"]}),
          ~s("content-type": #{wire.headers["content-type"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    public = Base.url_decode64!("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", padding: false)
    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [public, :ed25519])
  end

  defp server(response, endpoint \\ nil) do
    HTTPServer.start(fn wire ->
      if wire.method == :GET do
        base = "http://" <> wire.headers["host"]

        wallet = %{
          "id" => base <> "/wallet",
          "assetCode" => "USD",
          "assetScale" => 2,
          "authServer" => endpoint || base <> @auth_path,
          "resourceServer" => "https://payments.example/tenant"
        }

        {200, [], Jason.encode!(wallet)}
      else
        if is_map(response), do: {200, [], Jason.encode!(response)}, else: response
      end
    end)
  end

  defp invoke(argv, input \\ "") do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io([input: input], fn -> send(self(), {:status, CLI.run(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:stdout, stdout}
    assert_received {:status, status}
    {stdout, stderr, status}
  end
end
