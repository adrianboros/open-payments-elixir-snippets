defmodule OpenPaymentsSnippets.Commands.PaymentMacros do
  @moduledoc false

  alias OpenPaymentsSnippets.{GrantSession, Input, PaymentSession}

  alias OpenPaymentsSnippets.Commands.{
    GrantContinuation,
    PaymentAuthorization,
    PaymentFinish,
    PaymentPreparation,
    PaymentQuote,
    PaymentStart
  }

  @spec initialize(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def initialize(source, options) do
    with {:ok, data} <- Input.json(source, "payment macro"),
         {:ok, payment, scenario} <- input(data),
         {:ok, result} <-
           PaymentStart.from_map(payment, Keyword.put(options, :scenario, scenario)) do
      advance(result.session, options, :initialize, nil, [step("payment start", result)], 8)
    else
      {:error, message} when is_binary(message) -> invalid(message)
      error -> error
    end
  end

  @spec finalize(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def finalize(target, options) do
    with {:ok, path} <- session_path(target, options),
         {:ok, session, _response, _scenario} <- snapshot(path, options) do
      advance(path, options, :finalize, session["payment"]["stage"], [], 8)
    end
  end

  defp input(data) when is_map(data) do
    with true <-
           map_size(
             Map.drop(data, ~w(receiver receiveAmount finishUri metadata senderAuthorization))
           ) == 0,
         {:ok, authorization, _finish} <-
           PaymentAuthorization.decode_input(data["senderAuthorization"]) do
      {:ok, Map.delete(data, "senderAuthorization"),
       %{"version" => 1, "name" => "quote-payment", "sender_authorization" => authorization}}
    else
      _ ->
        invalid(
          "Invalid payment macro. Supply payment-start fields and senderAuthorization with debitAmount and finishUri."
        )
    end
  end

  defp input(_data), do: invalid("Payment macro must be a JSON object.")

  defp session_path(target, _options) when target in [nil, ""],
    do: invalid("Supply a private macro session, or - for a JSON session descriptor.")

  defp session_path("-", options) do
    if options[:callback_file] == "-" do
      invalid("Session descriptor and callback cannot both use stdin. Supply one as a file.")
    else
      with {:ok, data} <- Input.json("-", "macro session descriptor"),
           %{"session" => path} when is_binary(path) and path != "" <- data do
        {:ok, path}
      else
        _ -> invalid("Supply a JSON session descriptor with a session path.")
      end
    end
  end

  defp session_path(path, _options), do: {:ok, path}

  defp snapshot(path, options) do
    GrantSession.transaction(path, fn _path, session ->
      with {:ok, response, _received} <- GrantSession.validate(session),
           {:ok, payment, _request, _sender, _receiver} <- PaymentSession.context(session),
           %{"version" => 1, "name" => "quote-payment", "sender_authorization" => data} <-
             payment["scenario"],
           {:ok, authorization, _finish} <- PaymentAuthorization.decode_input(data),
           {:ok, _client, _key} <- GrantSession.client(session, options) do
        {:ok, session, response, authorization}
      else
        {:error, {:argument, _}} = error -> error
        _ -> invalid("Invalid macro session. Use payment initialize to record its scenario.")
      end
    end)
  end

  defp advance(_path, _options, _mode, _continue_stage, _steps, 0),
    do:
      {:error,
       {:operation,
        "Payment macro step limit reached. Inspect the saved session before resuming."}}

  defp advance(path, options, mode, continue_stage, steps, remaining) do
    with {:ok, session, response, authorization} <- snapshot(path, options) do
      stage = session["payment"]["stage"]
      pending? = stage in ["receiver-grant", "sender-grant"] and is_nil(response.access_token)

      cond do
        Keyword.has_key?(options, :callback_file) and not (pending? and stage == continue_stage) ->
          invalid("This macro stage does not accept an interaction callback.")

        pending? and session["kind"] == "token-revocation" ->
          invalid(
            "The active token was revoked. Resolve authorization explicitly before resuming."
          )

        pending? and mode == :finalize and stage == continue_stage ->
          if Map.get(response, :interact) && not Keyword.has_key?(options, :callback_file),
            do: {:ok, decorate(pending(path, stage, response), steps)},
            else: continue(path, options, session, steps, remaining)

        pending? ->
          {:ok, decorate(pending(path, stage, response), steps)}

        stage == "receiver-grant" ->
          perform(
            "payment prepare",
            fn -> PaymentPreparation.run(path, options) end,
            path,
            options,
            mode,
            continue_stage,
            steps,
            remaining
          )

        stage == "incoming-ready" ->
          perform(
            "payment authorize",
            fn -> PaymentAuthorization.from_map(path, authorization, options) end,
            path,
            options,
            mode,
            continue_stage,
            steps,
            remaining
          )

        stage == "sender-grant" ->
          perform(
            "payment quote",
            fn -> PaymentQuote.run(path, options) end,
            path,
            options,
            mode,
            continue_stage,
            steps,
            remaining
          )

        stage == "quote-ready" and mode == :initialize ->
          terminal("payment quote", fn -> PaymentQuote.run(path, options) end, steps)

        stage in ["quote-ready", "outgoing-created"] ->
          terminal("payment finish", fn -> PaymentFinish.run(path, options) end, steps)
      end
    end
  end

  defp continue(path, options, session, steps, remaining) do
    case GrantContinuation.run(path, Keyword.put(options, :pending_only, true)) do
      {:ok, result} ->
        steps = steps ++ [step("grant continue", result)]

        if result.status in ["waiting", "pending", "subject"] do
          {:ok,
           decorate(
             Map.merge(result, %{session: Path.expand(path), stage: session["payment"]["stage"]}),
             steps
           )}
        else
          options = Keyword.drop(options, [:callback_file, :hash_encoding])
          advance(path, options, :finalize, nil, steps, remaining - 1)
        end

      error ->
        error
    end
  end

  defp perform(command, action, path, options, mode, continue_stage, steps, remaining) do
    case action.() do
      {:ok, result} ->
        steps = steps ++ [step(command, result)]

        if mode == :initialize and result.stage == "quote-ready",
          do: {:ok, decorate(result, steps)},
          else: advance(path, options, mode, continue_stage, steps, remaining - 1)

      error ->
        error
    end
  end

  defp terminal(command, action, steps) do
    case action.() do
      {:ok, result} -> {:ok, decorate(result, steps ++ [step(command, result)])}
      error -> error
    end
  end

  defp pending(path, stage, response) do
    result = %{status: "pending", stage: stage, session: Path.expand(path), saved: false}

    case Map.get(response, :interact) do
      %{redirect: url} when is_binary(url) -> Map.put(result, :consent_url, url)
      _ -> result
    end
  end

  defp step(command, result),
    do: result |> Map.take([:status, :saved, :wait_seconds]) |> Map.put(:command, command)

  defp decorate(result, steps),
    do:
      Map.merge(result, %{
        scenario: "quote-payment",
        steps: steps,
        saved: Enum.any?(steps, & &1.saved)
      })

  defp invalid(message), do: {:error, {:argument, message}}
end
