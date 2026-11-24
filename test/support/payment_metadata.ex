defmodule OpenPaymentsSnippets.Test.PaymentMetadata do
  @moduledoc false
  import ExUnit.Assertions

  def assert_enriched(actual, original) do
    metadata = actual["metadata"]
    details = metadata["openPaymentsSnippets"]
    assert details["sdk"] == "open_payments_elixir"
    assert details["sdkVersion"] == to_string(Application.spec(:open_payments_elixir, :vsn))

    assert details["sdkSource"] ==
             Application.fetch_env!(:open_payments_elixir_snippets, :sdk_source)

    assert details["cliVersion"] ==
             to_string(Application.spec(:open_payments_elixir_snippets, :vsn))

    assert is_binary(details["scenario"]) and details["scenario"] != ""
    assert is_binary(details["runId"]) and details["runId"] != ""

    assert is_binary(metadata["description"]) or
             Map.has_key?(original["metadata"] || %{}, "description")

    assert Map.delete(actual, "metadata") == Map.delete(original, "metadata")

    retained = Map.delete(metadata, "openPaymentsSnippets")

    retained =
      if Map.has_key?(original["metadata"] || %{}, "description"),
        do: retained,
        else: Map.delete(retained, "description")

    assert retained == Map.delete(original["metadata"] || %{}, "openPaymentsSnippets")
    actual
  end
end
