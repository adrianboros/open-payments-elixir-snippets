defmodule ConsumerCheck do
  @moduledoc false
  @root Path.expand("..", __DIR__)
  @sdk_files ~w(mix.exs mix.lock README.md LICENSE CHANGELOG.md lib priv)

  def run(arguments) do
    {options, extra, invalid} =
      OptionParser.parse(arguments,
        strict: [offline: :boolean, sdk_path: :string, sdk_ref: :string, sdk_archive: :string]
      )

    unless extra == [] and invalid == [] and
             not (Keyword.has_key?(options, :sdk_archive) and
                    (Keyword.has_key?(options, :sdk_path) or Keyword.has_key?(options, :sdk_ref))),
           do:
             raise(
               ArgumentError,
               "usage: elixir scripts/check_consumer.exs [--offline] [--sdk-path directory --sdk-ref revision | --sdk-archive tar]"
             )

    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-cli-consumer-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      archive = archive!(directory, options)
      unpack!(archive, Path.join(directory, "open-payments-elixir"))
      cli = Path.join(directory, "open-payments-elixir-snippets")
      copy_cli!(cli)
      production = environment("prod", options[:offline])
      testing = environment("test", options[:offline])

      run!(["deps.get", "--check-locked"], cli, production)
      run!(["compile", "--warnings-as-errors"], cli, production)
      run!(["escript.build", "--warnings-as-errors"], cli, production)
      executable = Path.join(cli, "open-payments")
      run!(["check"], cli, testing)
      run!(["run", "scripts/consumer_smoke.exs", executable], cli, testing)

      run!(
        [
          "test",
          "--only",
          "consumer_flow",
          "test/open_payments_snippets/payment_flow_test.exs",
          "test/open_payments_snippets/payment_finish_test.exs",
          "test/open_payments_snippets/payment_macros_test.exs"
        ],
        cli,
        List.keystore(
          testing,
          "OPEN_PAYMENTS_TEST_EXECUTABLE",
          0,
          {"OPEN_PAYMENTS_TEST_EXECUTABLE", executable}
        )
      )

      IO.puts(
        "CLI consumer check passed on Elixir #{System.version()}/OTP #{System.otp_release()}"
      )
    after
      File.rm_rf!(directory)
    end
  end

  defp archive!(directory, options) do
    if options[:sdk_archive] do
      archive = Path.expand(options[:sdk_archive])
      hash = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
      IO.puts("SDK archive SHA256 #{hash}")
      archive
    else
      sdk = Path.expand(options[:sdk_path] || Path.join(@root, "../open-payments-elixir"))

      {revision, 0} =
        System.cmd(
          "git",
          [
            "-C",
            sdk,
            "rev-parse",
            "--verify",
            "--end-of-options",
            (options[:sdk_ref] || "HEAD") <> "^{commit}"
          ],
          stderr_to_stdout: true
        )

      revision = String.trim(revision)
      unless Regex.match?(~r/\A[0-9a-f]{40,64}\z/, revision), do: raise("Invalid SDK commit")
      archive = Path.join(directory, "sdk.tar")

      {_output, 0} =
        System.cmd(
          "git",
          [
            "-C",
            sdk,
            "archive",
            "--format=tar",
            "--output=" <> archive,
            revision,
            "--" | @sdk_files
          ],
          stderr_to_stdout: true
        )

      IO.puts("SDK commit #{revision}")
      archive
    end
  end

  defp unpack!(archive, destination) do
    {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:memory])

    for {name, contents} <- entries do
      name = List.to_string(name)
      parts = Path.split(name)

      unless Path.type(name) == :relative and ".." not in parts and
               (name in @sdk_files or hd(parts) in ["lib", "priv"]),
             do: raise("Unexpected SDK archive entry")

      target = Path.join(destination, name)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, contents)
    end

    unless File.regular?(Path.join(destination, "mix.exs")), do: raise("Missing SDK mix.exs")
  end

  defp copy_cli!(destination) do
    File.mkdir!(destination)

    for name <- ~w(mix.exs mix.lock .formatter.exs README.md lib test) do
      File.cp_r!(Path.join(@root, name), Path.join(destination, name))
    end

    File.mkdir!(Path.join(destination, "scripts"))

    for name <- ~w(check_consumer.exs consumer_smoke.exs) do
      File.cp!(Path.join(@root, "scripts/" <> name), Path.join(destination, "scripts/" <> name))
    end
  end

  defp environment(mode, offline?) do
    [
      {"MIX_ENV", mode},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_LOCKFILE", nil},
      {"OPEN_PAYMENTS_TEST_EXECUTABLE", nil},
      {"HEX_OFFLINE", if(offline?, do: "1", else: System.get_env("HEX_OFFLINE"))}
    ] ++
      Enum.map(
        ~w(WALLET_ADDRESS KEY_ID PRIVATE_KEY_FILE PRIVATE_KEY_BASE64 PRIVATE_KEY ACCESS_TOKEN),
        &{&1, nil}
      )
  end

  defp run!(arguments, directory, environment) do
    IO.puts("Checking: mix #{Enum.join(arguments, " ")}")

    {_output, status} =
      System.cmd("mix", arguments,
        cd: directory,
        env: environment,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("Consumer command failed: mix #{hd(arguments)}")
  end
end

ConsumerCheck.run(System.argv())
