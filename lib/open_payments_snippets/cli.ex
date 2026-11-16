defmodule OpenPaymentsSnippets.CLI do
  @moduledoc """
  Command-line entry point for the Open Payments SDK examples.

  `run/1` writes results to stdout, diagnostics to stderr, and returns an exit
  status. `main/1` is the escript entry point and terminates the VM with that status.
  """

  @help """
  Usage: open-payments [command] [options]

  Commands:
    help                Show this help
    version             Show CLI, SDK, and Open Payments specification versions

  Options:
    -h, --help          Show help
    -v, --version       Show version information
    --json              Format version information as JSON

  Exit statuses:
    0  Success
    1  Operation or runtime failure
    2  Invalid arguments or configuration
  """

  @doc "Runs the executable and exits with the command's status."
  @spec main([String.t()]) :: no_return()
  def main(argv), do: System.halt(run(argv))

  @doc "Runs a command without terminating the calling process."
  @spec run([String.t()]) :: 0 | 1 | 2
  def run(argv) do
    {options, arguments, invalid} =
      OptionParser.parse(argv,
        strict: [help: :boolean, version: :boolean, json: :boolean],
        aliases: [h: :help, v: :version]
      )

    json? = Keyword.get(options, :json, false)

    cond do
      invalid != [] ->
        argument_error("Unknown option or invalid option value.")

      options[:help] && options[:version] ->
        argument_error("Choose either help or version.")

      arguments not in [[], ["help"], ["version"]] ->
        argument_error("Unknown command or unexpected arguments.")

      options[:version] && arguments == ["help"] ->
        argument_error("Choose either help or version.")

      options[:help] || arguments == ["help"] ||
          (arguments == [] && !options[:version]) ->
        print_help(json?)

      true ->
        print_version(json?)
    end
  end

  defp print_help(true), do: argument_error("The --json option requires version.")

  defp print_help(false) do
    IO.write(@help)
    0
  end

  defp print_version(json?) do
    versions = %{
      cli_version: application_version(:open_payments_elixir_snippets),
      sdk_version: application_version(:open_payments_elixir),
      specification_version: OpenPayments.specification_version(),
      specification_revision: OpenPayments.Specification.revision()
    }

    IO.puts(format_versions(versions, json?))
    0
  end

  defp format_versions(versions, true), do: Jason.encode!(versions)

  defp format_versions(versions, false) do
    """
    open-payments #{versions.cli_version}
    SDK #{versions.sdk_version}
    Open Payments specification #{versions.specification_version}
    Specification revision #{versions.specification_revision}
    """
    |> String.trim_trailing()
  end

  defp application_version(application) do
    application |> Application.spec(:vsn) |> to_string()
  end

  defp argument_error(message) do
    IO.puts(:stderr, "Error: #{message}\nRun open-payments help for usage.")
    2
  end
end
