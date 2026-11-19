defmodule OpenPaymentsSnippets.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_payments_elixir_snippets,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: OpenPaymentsSnippets.CLI, name: "open-payments"],
      deps: [
        {:open_payments_elixir, path: "../open-payments-elixir"},
        {:jason, "~> 1.4"}
      ],
      aliases: [
        check: ["format --check-formatted", "compile --warnings-as-errors", "test"]
      ],
      package: [files: ["lib", "examples", "mix.exs", "README.md"]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
