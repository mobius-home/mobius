defmodule Mobius.Metrics.TableTest do
  use ExUnit.Case, async: true

  alias Mobius.Metrics.Table

  setup do
    table_name = :metrics_table_test_table
    :ok = Table.init(table_name: table_name)

    {:ok, %{table: table_name}}
  end

  test "initialize counter on first update", %{table: table} do
    :ok = Table.put(table, "counter event 1", :counter, 1)

    result = Table.get_entries_by_event_name(table, "counter event 1")

    assert result == [{"counter event 1", :counter, 1, %{}}]
  end

  test "increament counter after first report", %{table: table} do
    :ok = Table.put(table, "counter event 2", :counter, 1)
    :ok = Table.put(table, "counter event 2", :counter, 1)

    result = Table.get_entries_by_event_name(table, "counter event 2")

    assert result == [{"counter event 2", :counter, 2, %{}}]
  end

  test "increament counter with inc_counter/3", %{table: table} do
    event_name = "increament helper event"

    :ok = Table.inc_counter(table, event_name)
    :ok = Table.inc_counter(table, event_name)
    :ok = Table.inc_counter(table, event_name)

    result = Table.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :counter, 3, %{}}]
  end

  test "initialize last value on first report", %{table: table} do
    event_name = "last value event 1"

    :ok = Table.put(table, event_name, :last_value, 123)

    result = Table.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :last_value, 123, %{}}]
  end

  test "update last value after first report", %{table: table} do
    event_name = "last value event 2"

    :ok = Table.put(table, event_name, :last_value, 321)
    :ok = Table.put(table, event_name, :last_value, 765)

    result = Table.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :last_value, 765, %{}}]
  end
end
