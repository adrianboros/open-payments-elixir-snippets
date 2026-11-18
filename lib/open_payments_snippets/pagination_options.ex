defmodule OpenPaymentsSnippets.PaginationOptions do
  @moduledoc false

  alias OpenPayments.Error
  alias OpenPayments.Types.Pagination

  @spec parse(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def parse(options) do
    data =
      for {key, value} <- Keyword.take(options, [:first, :last, :cursor]),
          into: %{},
          do: {Atom.to_string(key), value}

    if map_size(data) == 0 do
      {:ok, []}
    else
      with {:ok, pagination} <- Pagination.from_map(data), do: {:ok, [pagination: pagination]}
    end
  end
end
