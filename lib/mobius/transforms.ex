defmodule Mobius.Transforms do
  @moduledoc "Useful CSV transform functions"

  @doc "Row transform: Add a column with the timestamp converted to UTC ISO time"
  @spec add_date_time(list, non_neg_integer(), keyword(), [{:label, any}]) :: list
  def add_date_time(["timestamp" | _] = row, 0, _context, _extra_args),
    do: row ++ ["local dt"]

  def add_date_time(row, index, _context, _extra_args) when index > 0 do
    [timestamp | _] = row
    {seconds, _} = Integer.parse(timestamp)
    {:ok, dt} = DateTime.from_unix(seconds)
    row ++ [DateTime.to_string(dt)]
  end

  @doc "Row transform: Add a column with the difference between the value in a given column and some base value in context"
  @spec add_delta(list, non_neg_integer(), [{:base, number()}], [
          {:label, String.t()} | {:column, non_neg_integer()}
        ]) :: list
  def add_delta(row, 0, _context, extra_args),
    do: row ++ [Keyword.get(extra_args, :label, "delta")]

  def add_delta(row, _row_index, context, extra_args) do
    maximum = Keyword.fetch!(context, :base)
    column_index = Keyword.fetch!(extra_args, :column)
    {value, _} = Integer.parse(Enum.at(row, column_index))
    delta = maximum - value
    row ++ [Integer.to_string(delta)]
  end

  @doc "Context function: Calculate the maximum of all numerical values in a given column and make it the base value in the returned context"
  @spec find_maximum(list, keyword) :: keyword
  def find_maximum(rows, extra_args) do
    column_index = Keyword.fetch!(extra_args, :column)
    name = Keyword.get(extra_args, :name_maximum, :maximum)

    maximum =
      rows
      |> Enum.drop(1)
      |> Enum.reduce(0, fn row, acc ->
        {value, _} = Enum.at(row, column_index) |> Integer.parse()
        if value > acc, do: value, else: acc
      end)

    [{name, maximum}]
  end
end
