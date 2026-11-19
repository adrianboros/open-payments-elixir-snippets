ExUnit.start()
[executable] = System.argv()
Application.put_env(:open_payments_elixir_snippets, :consumer_executable, Path.expand(executable))

defmodule ExecutableConsumerTest do
  use ExUnit.Case, async: false
  alias OpenPaymentsSnippets.Test.Executable

  # Public RFC 8032 vector 1, never an operational key.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-consumer-key-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    key = Path.join(directory, "rfc8032.pem")
    File.write!(key, @pem)
    previous = Enum.map(~w(KEY_ID PRIVATE_KEY_FILE), &{&1, System.get_env(&1)})
    System.put_env("KEY_ID", "consumer-key")
    System.put_env("PRIVATE_KEY_FILE", key)

    on_exit(fn ->
      File.rm_rf!(directory)

      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    %{key: key}
  end

  test "help includes the complete staged flow from outside the checkout" do
    assert {stdout, "", 0} = run(["help"])

    for command <- ~w(start prepare authorize quote finish initialize finalize),
        do: assert(stdout =~ "payment #{command}")

    assert stdout =~ "--yes"
    assert stdout =~ "grant verify-callback"
  end

  test "version metadata matches the isolated SDK consumer" do
    assert {stdout, "", 0} = run(["version", "--json"])
    version = Jason.decode!(stdout)

    assert version["cli_version"] ==
             Application.spec(:open_payments_elixir_snippets, :vsn) |> to_string()

    assert version["sdk_version"] == Application.spec(:open_payments_elixir, :vsn) |> to_string()
    assert version["specification_version"] == OpenPayments.specification_version()
  end

  test "pointer arguments preserve dollar signs and opaque paths" do
    assert {stdout, "", 0} = run(["pointer", "resolve", "$wallet.example/alice%2fbob", "--json"])
    assert Jason.decode!(stdout) == %{"url" => "https://wallet.example/alice%2fbob"}
  end

  test "private key validation loads its runtime crypto dependencies", c do
    assert {stdout, "", 0} = run(["keys", "validate", "--json"])
    assert Jason.decode!(stdout) == %{"valid" => true, "key_id" => "consumer-key"}
    assert File.read!(c.key) == @pem
  end

  test "public export works with only the executable and public key fixture" do
    assert {stdout, "", 0} = run(["keys", "public", "--json"])
    assert Jason.decode!(stdout)["x"] == "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
    refute stdout =~ "PRIVATE KEY"
  end

  test "environment-file templates, UTF-8 stdin and malformed input have correct exits", c do
    env_file = Path.join(Path.dirname(c.key), "example.env")
    settings = "WALLET_ADDRESS='https://client.example/wallet'\nLABEL='from-file'\n"
    File.write!(env_file, settings)

    payload = %{
      "client" => %{"$var" => "WALLET_ADDRESS"},
      "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]},
      "interact" => %{"start" => ["redirect"]}
    }

    template = Jason.encode!(Map.put(payload, "label", %{"$var" => "LABEL"}))

    assert {input, "", 0} =
             run(
               [
                 "input",
                 "render",
                 "-",
                 "--env-file",
                 env_file,
                 "--var",
                 "LABEL=Café 🌍",
                 "--json"
               ],
               template
             )

    assert Jason.decode!(input)["label"] == "Café 🌍"
    assert File.read!(env_file) == settings
    assert {_, "", 0} = run(["grant", "validate", "-", "--json"], input)
    assert {"", stderr, 2} = run(["grant", "validate", "-"], <<255>>)
    assert stderr =~ "Error:"
    assert {"", _, 2} = run(["wallet", "get", "--yes"])
  end

  test "callback checking works offline with pasted whitespace and preserves the saved session",
       c do
    directory = Path.dirname(c.key)
    path = Path.join(directory, "session.json")
    callback = Path.join(directory, "callback.txt")
    uri = "https://client.example/return?state=consumer"

    session = %{
      "version" => 1,
      "kind" => "grant-request",
      "state" => "ready",
      "wallet_address" => "https://client.example/signer",
      "key_id" => "consumer-key",
      "grant_endpoint" => "https://server.example.com/tx",
      "received_at" => DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601(),
      "finish" => %{"method" => "redirect", "uri" => uri, "nonce" => "VJLO6A4CATR0KRO"},
      "response" => %{
        "continue" => %{
          "uri" => "https://auth.example/continue",
          "wait" => 0,
          "access_token" => %{"value" => "consumer-continuation-secret"}
        },
        "interact" => %{
          "redirect" => "https://auth.example/consent",
          "finish" => "MBDOFXG4Y5CVJCX821LH"
        }
      }
    }

    original = Jason.encode!(session)
    File.write!(path, original)
    File.chmod!(path, 0o600)

    url =
      uri <>
        "&" <>
        URI.encode_query(%{
          "hash" => "x+gguKWTj8rQf7d7i3w3UhzvuJ5bpOlKyAlVpLxBffY=",
          "interact_ref" => "4IFWWIKYB2PQ6U56NL1"
        })

    File.write!(callback, "\n  " <> url <> "\n\n")
    File.chmod!(callback, 0o600)
    for name <- ~w(KEY_ID PRIVATE_KEY_FILE), do: System.delete_env(name)

    assert {"{\"valid\":true}\n", "", 0} =
             run(["grant", "verify-callback", path, "--callback-file", callback, "--json"])

    assert {"Valid interaction callback\n", "", 0} =
             run(
               ["grant", "verify-callback", path, "--callback-file", "-"],
               " \n" <> url <> "\n\n"
             )

    assert {"", stderr, 2} =
             run(
               ["grant", "verify-callback", path, "--callback-file", "-"],
               String.replace(url, "state=consumer", "state=other")
             )

    assert stderr =~ "payment direction and consent stage"
    assert File.read!(path) == original
    refute File.exists?(path <> ".lock")
  end

  test "production archive contains application code and resources only" do
    executable = Application.fetch_env!(:open_payments_elixir_snippets, :consumer_executable)
    {:ok, sections} = :escript.extract(String.to_charlist(executable), [])
    {:archive, archive} = List.keyfind(sections, :archive, 0)
    {:ok, entries} = :zip.extract(archive, [:memory])
    names = Enum.map(entries, fn {name, _contents} -> List.to_string(name) end)

    for module <-
          ~w(Elixir.OpenPaymentsSnippets.CLI.beam Elixir.OpenPayments.Client.beam Elixir.OpenPayments.Specification.beam) do
      assert Enum.any?(names, &(Path.basename(&1) == module))
    end

    for name <- names do
      case Path.split(name) do
        [filename] ->
          assert Path.extname(filename) in [".beam", ".app"] or
                   filename in ~w(SOURCE.json auth-server.json resource-server.json wallet-address-server.json)

        [_application, section | _] ->
          assert section in ["ebin", "priv"]
      end

      refute name =~ "OpenPaymentsSnippets.Test."
    end
  end

  defp run(arguments, input \\ "") do
    executable = Application.fetch_env!(:open_payments_elixir_snippets, :consumer_executable)
    {stdout, stderr, status} = Executable.run(executable, arguments, input)
    refute stdout <> stderr =~ "PRIVATE KEY"
    {stdout, stderr, status}
  end
end
