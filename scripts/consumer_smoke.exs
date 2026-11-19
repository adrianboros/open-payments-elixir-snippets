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

    for command <- ~w(start prepare authorize quote finish),
        do: assert(stdout =~ "payment #{command}")

    assert stdout =~ "--yes"
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

  test "actual UTF-8 stdin and malformed input have correct exits" do
    payload = %{
      "client" => "https://client.example/wallet",
      "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]},
      "interact" => %{"start" => ["redirect"]}
    }

    input = Jason.encode!(Map.put(payload, "label", "Café 🌍"))
    assert {_, "", 0} = run(["grant", "validate", "-", "--json"], input)
    assert {"", stderr, 2} = run(["grant", "validate", "-"], <<255>>)
    assert stderr =~ "Error:"
    assert {"", _, 2} = run(["wallet", "get", "--yes"])
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
