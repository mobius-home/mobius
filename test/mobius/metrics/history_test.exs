defmodule Mobius.Metrics.HistoryTest do
  use ExUnit.Case, aysnc: true

  alias Mobius.Metrics.{History, Table}

  setup do
    table = :history_test

    Table.init(table_name: table)

    Table.put(table, [:test], :counter, nil)

    {:ok, %{table: table}}
  end

  test "takes a snapshot of the data that is currently in the table", %{table: table} do
    history = History.init(table_name: table)
    date_time = DateTime.utc_now()

    new_history = History.snapshot(history, date_time)

    assert [{date_time, [{[:test], :counter, 1, %{}}]}] == History.view(new_history)
  end
end
