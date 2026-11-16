defmodule OpenPaymentsSnippets.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OpenPaymentsSnippets.CLI

  test "no arguments, help command, and help flags show available commands" do
    for argv <- [[], ["help"], ["--help"], ["-h"], ["version", "--help"]] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""
      assert stdout =~ "Usage: open-payments"
      assert stdout =~ "help"
      assert stdout =~ "version"
      assert stdout =~ "--json"
      assert stdout =~ "0  Success"
      assert stdout =~ "1  Operation or runtime failure"
      assert stdout =~ "2  Invalid arguments or configuration"
    end
  end

  test "version command and flags report actual dependency metadata" do
    for argv <- [["version"], ["--version"], ["-v"]] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""

      assert stdout == """
             open-payments #{Application.spec(:open_payments_elixir_snippets, :vsn)}
             SDK #{Application.spec(:open_payments_elixir, :vsn)}
             Open Payments specification #{OpenPayments.specification_version()}
             Specification revision #{OpenPayments.Specification.revision()}
             """
    end
  end

  test "JSON version works before and after the command and with aliases" do
    for argv <- [
          ["version", "--json"],
          ["--json", "version"],
          ["--version", "--json"],
          ["--json", "-v"]
        ] do
      {stdout, stderr, status} = invoke(argv)

      assert status == 0
      assert stderr == ""

      assert Jason.decode!(stdout) == %{
               "cli_version" => to_string(Application.spec(:open_payments_elixir_snippets, :vsn)),
               "sdk_version" => to_string(Application.spec(:open_payments_elixir, :vsn)),
               "specification_version" => OpenPayments.specification_version(),
               "specification_revision" => OpenPayments.Specification.revision()
             }
    end
  end

  test "standard boolean negation and values control JSON output" do
    for argv <- [["version", "--no-json"], ["version", "--json=false"]] do
      {stdout, stderr, status} = invoke(argv)
      assert status == 0
      assert stderr == ""
      assert stdout =~ "open-payments "
    end

    {stdout, "", 0} = invoke(["version", "--json=true"])
    assert is_map(Jason.decode!(stdout))
  end

  test "unknown options and invalid option values fail even with help" do
    for argv <- [
          ["--unknown"],
          ["--help", "--unknown"],
          ["version", "--json=invalid"],
          ["--help=invalid"],
          ["--version=invalid"],
          ["version", "-j"]
        ] do
      assert_argument_error(argv, "Unknown option or invalid option value.")
    end
  end

  test "unknown commands, extra arguments, and missing future subcommands fail" do
    for argv <- [
          ["unknown"],
          ["version", "extra"],
          ["help", "extra"],
          ["pointer"],
          ["version", "--", "--json"],
          ["--help", "unknown"],
          ["--version", "unknown"]
        ] do
      assert_argument_error(argv, "Unknown command or unexpected arguments.")
    end
  end

  test "conflicting help and version requests fail" do
    for argv <- [["--help", "--version"], ["help", "--version"]] do
      assert_argument_error(argv, "Choose either help or version.")
    end
  end

  test "JSON requires a version request" do
    for argv <- [["--json"], ["help", "--json"], ["--help", "--json"]] do
      assert_argument_error(argv, "The --json option requires version.")
    end
  end

  test "diagnostics omit supplied argument and option values" do
    for argv <- [
          ["sensitive-input"],
          ["--unknown=sensitive-input"],
          ["version", "--json=sensitive-input"]
        ] do
      {"", stderr, 2} = invoke(argv)
      refute stderr =~ "sensitive-input"
      assert stderr =~ "Error:"
    end
  end

  defp assert_argument_error(argv, message) do
    {stdout, stderr, status} = invoke(argv)
    assert status == 2
    assert stdout == ""
    assert stderr == "Error: #{message}\nRun open-payments help for usage.\n"
  end

  defp invoke(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:status, CLI.run(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:stdout, stdout}
    assert_received {:status, status}
    {stdout, stderr, status}
  end
end
