defmodule OpenPaymentsSnippets.InputExamplesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias OpenPaymentsSnippets.{CLI, Environment}
  alias OpenPaymentsSnippets.Test.HTTPServer

  @examples Path.expand("../../examples", __DIR__)
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
  -----END PRIVATE KEY-----
  """

  setup do
    directory = Path.join(System.tmp_dir!(), "op-input-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    names =
      ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 ACCESS_TOKEN OP_EXAMPLE_VALUE)

    previous = Enum.map(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      File.rm_rf!(directory)

      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    %{directory: directory}
  end

  test "environment files are literal data, support quotes/comments/export/CRLF and never mutate the shell",
       c do
    marker = Path.join(c.directory, "must-not-exist")

    path =
      env(
        c,
        "literal",
        """
        # Comment
        export WALLET_ADDRESS='$wallet.example/alice#fragment'
        OP_EXAMPLE_VALUE = "Café # quoted" # trailing comment
        EMPTY=
        COMMAND=$(touch #{marker})
        EQUALS=a=b # comment
        """
        |> String.replace("\n", "\r\n")
      )

    assert {:ok, options} = Environment.prepare(env_file: path)
    assert Environment.get(options, "WALLET_ADDRESS") == "$wallet.example/alice#fragment"
    assert Environment.get(options, "OP_EXAMPLE_VALUE") == "Café # quoted"
    assert Environment.get(options, "EMPTY") == ""
    assert Environment.get(options, "COMMAND") == "$(touch #{marker})"
    assert Environment.get(options, "EQUALS") == "a=b"
    refute File.exists?(marker)
    refute System.get_env("WALLET_ADDRESS")
  end

  test "last file wins, shell wins over files, and repeated var overrides affect only payloads",
       c do
    first = env(c, "first", "OP_EXAMPLE_VALUE=first\nWALLET_ADDRESS='$wallet.example/first'\n")
    second = env(c, "second", "OP_EXAMPLE_VALUE=second\n")
    assert {:ok, options} = Environment.prepare(env_file: first, env_file: second)
    assert Environment.get(options, "OP_EXAMPLE_VALUE") == "second"
    System.put_env("OP_EXAMPLE_VALUE", "shell")

    assert {:ok, options} =
             Environment.prepare(
               env_file: first,
               env_file: second,
               var: "OP_EXAMPLE_VALUE=override=1",
               var: "OP_EXAMPLE_VALUE=override=2",
               var: "WALLET_ADDRESS=$wallet.example/payload"
             )

    assert Environment.get(options, "OP_EXAMPLE_VALUE") == "shell"
    assert Environment.variable(options, "OP_EXAMPLE_VALUE") == {:ok, "override=2"}
    assert Environment.get(options, "WALLET_ADDRESS") == "$wallet.example/first"
    assert Environment.variable(options, "WALLET_ADDRESS") == {:ok, "$wallet.example/payload"}
  end

  test "invalid files and variables report safe errors before executing a command", c do
    for contents <- [
          "not an assignment secret-value",
          "KEY='unterminated-secret",
          "KEY='secret' trailing",
          <<255>>
        ] do
      path = env(c, "invalid", contents)
      assert {"", stderr, 2} = invoke(["version", "--env-file", path])
      refute stderr =~ "secret"
      refute stderr =~ path
    end

    assert {"", _, 2} = invoke(["version", "--env-file", "absent-private-file"])

    for value <- ["missing-equals", "=private-value", "bad-name=private-value"] do
      assert {"", stderr, 2} = render("{}", ["--var", value])
      refute stderr =~ "private-value"
    end

    assert {"", _, 2} = invoke(["wallet", "get", "--var", "ANY=value"])
    assert {"", _, 2} = invoke(["version", "--env-file"])
  end

  test "JSON references preserve string types, Unicode, dollar signs and quotes without injection" do
    literal = "Café 🌍 \"quoted\"\n$wallet.example/receiver\\path"

    input =
      Jason.encode!(%{
        "items" => [%{"$var" => "TEXT"}],
        "scale" => %{"$var" => "SCALE", "type" => "integer"},
        "value" => %{"$var" => "VALUE"},
        "literal" => "${TEXT}"
      })

    assert {stdout, "", 0} =
             render(input, [
               "--var",
               "TEXT=" <> literal,
               "--var",
               "SCALE=2",
               "--var",
               "VALUE=0001"
             ])

    assert Jason.decode!(stdout) == %{
             "items" => [literal],
             "scale" => 2,
             "value" => "0001",
             "literal" => "${TEXT}"
           }
  end

  test "missing, invalid and credential references fail without exposing values" do
    for reference <- [
          %{"$var" => "MISSING_EXAMPLE_VARIABLE"},
          %{"$var" => 3},
          %{"$var" => "bad\nname"},
          %{"$var" => "VALUE", "extra" => true},
          %{"$var" => "VALUE", "type" => "object"},
          %{"$var" => "VALUE", "type" => "integer"}
        ] do
      assert {"", stderr, 2} =
               render(Jason.encode!(reference), ["--var", "VALUE=private-invalid-value"])

      refute stderr =~ "private-invalid-value"
    end

    for name <-
          ~w(PRIVATE_KEY PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 ACCESS_TOKEN WALLET_KEY WALLET_SECRET) do
      assert {"", stderr, 2} =
               render(Jason.encode!(%{"$var" => name}), ["--var", name <> "=secret-value"])

      refute stderr =~ "secret-value"
    end
  end

  test "ordinary JSON still renders without variables and stdin failures have safe errors" do
    assert {"[\n  1,\n  true,\n  null\n]\n", "", 0} =
             invoke(["input", "render", "-"], "[1,true,null]")

    assert {"", _, 2} = render(<<255>>)
    assert {"", _, 2} = invoke(["input", "render"])
    assert {"", _, 2} = invoke(["input", "render", "absent-template"])
    assert {"", _, 2} = invoke(["keys", "validate"])
    assert {help, "", 0} = invoke(["input", "render", "--help", "--env-file", "absent-file"])
    assert help =~ "input render" and help =~ "--env-file" and help =~ "--var"
  end

  test "wallet discovery uses explicit files while command arguments and shell retain precedence",
       c do
    base =
      HTTPServer.start(fn _wire ->
        {200, [{"Content-Type", "application/json"}],
         Jason.encode!(%{
           "id" => "https://wallet.example/alice",
           "assetCode" => "SGD",
           "assetScale" => 2,
           "authServer" => "https://auth.example",
           "resourceServer" => "https://resources.example"
         })}
      end)

    path = env(c, "wallet", "WALLET_ADDRESS='#{base}/from-file'\n")
    assert {_, "", 0} = invoke(["wallet", "get", "--env-file", path, "--allow-http", "--json"])
    assert_received {:http_request, %{target: "/from-file"}}
    System.put_env("WALLET_ADDRESS", base <> "/from-shell")
    assert {_, "", 0} = invoke(["wallet", "get", "--env-file", path, "--allow-http"])
    assert_received {:http_request, %{target: "/from-shell"}}

    assert {_, "", 0} =
             invoke(["wallet", "get", base <> "/explicit", "--env-file", path, "--allow-http"])

    assert_received {:http_request, %{target: "/explicit"}}
  end

  test "key settings from env files stay private and explicit key flags override them", c do
    key = Path.join(c.directory, "key.pem")
    File.write!(key, @pem)
    path = env(c, "keys", "KEY_ID='file-key'\nPRIVATE_KEY_BASE64='#{Base.encode64(@pem)}'\n")
    assert {stdout, "", 0} = invoke(["keys", "validate", "--env-file", path, "--json"])
    assert Jason.decode!(stdout) == %{"valid" => true, "key_id" => "file-key"}

    assert {stdout, "", 0} =
             invoke([
               "keys",
               "validate",
               "--env-file",
               path,
               "--key-file",
               key,
               "--key-id",
               "flag-key",
               "--json"
             ])

    assert Jason.decode!(stdout)["key_id"] == "flag-key"
    refute stdout =~ "PRIVATE KEY"
    refute System.get_env("PRIVATE_KEY_BASE64")
    assert File.read!(key) == @pem
  end

  test "all checked-in examples render with typed fields and grant input validates directly", c do
    path = Path.join(@examples, "scenarios.env.example")
    flags = ["--env-file", path, "--var", "WALLET_ADDRESS=$wallet.example/sender"]

    for file <- Path.wildcard(Path.join(@examples, "*.json")) do
      assert {stdout, "", 0} = invoke(["input", "render", file, "--json"] ++ flags)
      data = Jason.decode!(stdout)
      refute stdout =~ "$var"

      codec =
        case Path.basename(file) do
          "incoming-payment.json" -> OpenPayments.Types.CreateIncomingPayment
          "quote.json" -> OpenPayments.Types.CreateQuote
          "outgoing-payment.json" -> OpenPayments.Types.CreateOutgoingPayment
          "grant.json" -> OpenPayments.Types.GrantRequest
          _ -> nil
        end

      if codec, do: assert(match?({:ok, _}, apply(codec, :from_map, [data])))

      for field <- ~w(receiveAmount incomingAmount debitAmount), is_map(data[field]) do
        assert data[field]["assetScale"] in 0..9
        assert is_binary(data[field]["value"])
      end
    end

    assert {stdout, "", 0} =
             invoke(["grant", "validate", Path.join(@examples, "grant.json"), "--json"] ++ flags)

    assert Jason.decode!(stdout) == %{"valid" => true}
    refute File.exists?(Path.join(c.directory, "session.json"))
  end

  defp env(c, name, contents) do
    path = Path.join(c.directory, name <> ".env")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  defp render(input, flags \\ []), do: invoke(["input", "render", "-", "--json"] ++ flags, input)

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
