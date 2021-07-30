defmodule Mobius.Metrics.MetricsTableTest do
  use ExUnit.Case, async: true

  alias Mobius.MetricsTable

  setup do
    table_name = :metrics_table_test_table
    MetricsTable.init(name: table_name, persistence_dir: "/does/not/matter/here")

    {:ok, %{table: table_name}}
  end

  test "initialize counter on first update", %{table: table} do
    :ok = MetricsTable.put(table, "counter event 1", :counter, 1)

    result = MetricsTable.get_entries_by_event_name(table, "counter event 1")

    assert result == [{"counter event 1", :counter, 1, %{}}]
  end

  test "increament counter after first report", %{table: table} do
    :ok = MetricsTable.put(table, "counter event 2", :counter, 1)
    :ok = MetricsTable.put(table, "counter event 2", :counter, 1)

    result = MetricsTable.get_entries_by_event_name(table, "counter event 2")

    assert result == [{"counter event 2", :counter, 2, %{}}]
  end

  test "increament counter with inc_counter/3", %{table: table} do
    event_name = "increament helper event"

    :ok = MetricsTable.inc_counter(table, event_name)
    :ok = MetricsTable.inc_counter(table, event_name)
    :ok = MetricsTable.inc_counter(table, event_name)

    result = MetricsTable.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :counter, 3, %{}}]
  end

  test "initialize last value on first report", %{table: table} do
    event_name = "last value event 1"

    :ok = MetricsTable.put(table, event_name, :last_value, 123)

    result = MetricsTable.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :last_value, 123, %{}}]
  end

  test "update last value after first report", %{table: table} do
    event_name = "last value event 2"

    :ok = MetricsTable.put(table, event_name, :last_value, 321)
    :ok = MetricsTable.put(table, event_name, :last_value, 765)

    result = MetricsTable.get_entries_by_event_name(table, event_name)

    assert result == [{event_name, :last_value, 765, %{}}]
  end
end
