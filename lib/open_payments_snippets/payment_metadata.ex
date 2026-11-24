defmodule OpenPaymentsSnippets.PaymentMetadata do
  @moduledoc false
  alias OpenPaymentsSnippets.Environment

  # Call only after the SDK has validated the caller's metadata. This reserved
  # namespace describes this execution; arbitrary caller metadata stays intact.
  def annotate(request, options, scenario) do
    metadata = request.metadata || %{}
    label = Environment.get(options, "TEST_SCENARIO") || metadata["testScenario"]
    scenario = if is_binary(label) and label != "", do: label, else: scenario

    run_id =
      Environment.get(options, "TEST_RUN_ID") ||
        Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    details = %{
      "sdk" => "open_payments_elixir",
      "sdkVersion" => Application.spec(:open_payments_elixir, :vsn) |> to_string(),
      "sdkSource" => Application.fetch_env!(:open_payments_elixir_snippets, :sdk_source),
      "cliVersion" => Application.spec(:open_payments_elixir_snippets, :vsn) |> to_string(),
      "scenario" => scenario,
      "runId" => run_id
    }

    metadata =
      metadata
      |> Map.put("openPaymentsSnippets", details)
      |> Map.put_new("description", "Open Payments via Elixir SDK - #{scenario}")

    %{request | metadata: metadata}
  end

  # A staged payment reuses the exact metadata saved before incoming creation,
  # keeping both sides correlated even when providers omit response metadata.
  def outgoing(request, incoming_request, options) do
    case get_in(incoming_request, ["metadata", "openPaymentsSnippets"]) do
      %{"sdk" => "open_payments_elixir", "runId" => run_id} when is_binary(run_id) ->
        %{request | metadata: incoming_request["metadata"]}

      _ ->
        annotate(%{request | metadata: incoming_request["metadata"]}, options, "payment-quote")
    end
  end

  def ensure(request, options, scenario) do
    case request.metadata do
      %{"openPaymentsSnippets" => %{"sdk" => "open_payments_elixir", "runId" => id}}
      when is_binary(id) ->
        request

      _ ->
        annotate(request, options, scenario)
    end
  end
end
