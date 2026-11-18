defmodule OpenPaymentsSnippets.Test.HTTPServer do
  @moduledoc false

  def start(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    ExUnit.Callbacks.start_supervised!({Task, fn -> serve(listener, owner, response) end})
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listener) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve(listener, owner, response) do
    case :gen_tcp.accept(listener) do
      {:ok, connection} ->
        {:ok, {:http_request, method, {:abs_path, target}, _version}} =
          :gen_tcp.recv(connection, 0, 5_000)

        headers = headers(connection, %{})
        :ok = :inet.setopts(connection, packet: :raw)
        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        body = if length == 0, do: "", else: elem(:gen_tcp.recv(connection, length, 5_000), 1)
        wire = %{method: method, target: target, headers: headers, body: body}
        send(owner, {:http_request, wire})
        result = if is_function(response, 1), do: response.(wire), else: response
        respond(connection, result)
        :gen_tcp.close(connection)
        serve(listener, owner, response)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(connection, result) do
    case :gen_tcp.recv(connection, 0, 5_000) do
      {:ok, {:http_header, _index, name, _reserved, value}} ->
        headers(connection, Map.put(result, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        result
    end
  end

  defp respond(_connection, :close), do: :ok

  defp respond(connection, {status, headers, body}) do
    :gen_tcp.send(connection, [
      "HTTP/1.1 #{status} Test response\r\n",
      "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ])
  end
end
