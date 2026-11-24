defmodule OpenPaymentsSnippets.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_payments_elixir_snippets,
      version: "0.1.0",
      elixir: "~> 1.17",
      lockfile:
        if(System.get_env("OPEN_PAYMENTS_SDK_PATH"), do: "mix.source.lock", else: "mix.lock"),
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: OpenPaymentsSnippets.CLI, name: "open-payments"],
      deps: [
        sdk_dependency(),
        {:jason, "~> 1.4"}
      ],
      aliases: [
        check: ["format --check-formatted", "compile --warnings-as-errors", "test"]
      ],
      package: [files: ["lib", "examples", "mix.exs", "README.md"]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [
      extra_applications: [:logger],
      env: [sdk_source: if(System.get_env("OPEN_PAYMENTS_SDK_PATH"), do: "local", else: "hex")]
    ]
  end

  defp sdk_dependency do
    case System.get_env("OPEN_PAYMENTS_SDK_PATH") do
      nil ->
        {:open_payments_elixir, "~> 1.0"}

      path ->
        path = Path.expand(path, __DIR__)

        unless path != __DIR__ and File.regular?(Path.join(path, "mix.exs")),
          do: raise("OPEN_PAYMENTS_SDK_PATH must point to an SDK source directory with mix.exs")

        {:open_payments_elixir, path: path}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
