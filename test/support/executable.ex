defmodule OpenPaymentsSnippets.Test.Executable do
  @moduledoc false

  def run(executable, arguments, input \\ "") do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-executable-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    stdin = Path.join(directory, "stdin")
    stderr = Path.join(directory, "stderr")

    try do
      for {path, contents} <- [{stdin, input}, {stderr, ""}] do
        File.write!(path, contents)
        File.chmod!(path, 0o600)
      end

      # Paths and arguments are positional parameters, never interpolated shell text.
      command_arguments = [
        "-c",
        ~s(input=$1; error=$2; shift 2; exec "$@" < "$input" 2> "$error"),
        "open-payments-test",
        stdin,
        stderr,
        Path.expand(executable) | arguments
      ]

      {stdout, status} = System.cmd("sh", command_arguments, cd: directory)

      {stdout, File.read!(stderr), status}
    after
      File.rm_rf!(directory)
    end
  end
end
