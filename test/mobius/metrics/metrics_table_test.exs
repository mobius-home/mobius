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

  test "remove a metric from the metric table", %{table: table} do
    event_name = "I will be removed"
    :ok = MetricsTable.put(table, event_name, :last_value, 1000)

    # ensure the metric is saved
    assert [{event_name, :last_value, 1000, %{}}] ==
             MetricsTable.get_entries_by_event_name(table, event_name)

    :ok = MetricsTable.remove(table, event_name, :last_value)

    # make sure removed
    assert [] == MetricsTable.get_entries_by_event_name(table, event_name)
  end

  test "update a sum of values", %{table: table} do
    metric_name = "sum"
    :ok = MetricsTable.update_sum(table, metric_name, 100)

    assert [{metric_name, :sum, 100, %{}}] ==
             MetricsTable.get_entries_by_event_name(table, metric_name)

    :ok = MetricsTable.update_sum(table, metric_name, 50)

    assert [{metric_name, :sum, 150, %{}}] ==
             MetricsTable.get_entries_by_event_name(table, metric_name)
  end

  test "handle summary telemetry", %{table: table} do
    metric_name = "summary"
    :ok = MetricsTable.put(table, metric_name, :summary, 100)

    assert [{^metric_name, :summary, %{accumulated: 100, max: 100, min: 100, reports: 1}, %{}}] =
             MetricsTable.get_entries_by_event_name(table, metric_name)

    :ok = MetricsTable.put(table, metric_name, :summary, 120)

    assert [{^metric_name, :summary, %{accumulated: 220, max: 120, min: 100, reports: 2}, %{}}] =
             MetricsTable.get_entries_by_event_name(table, metric_name)
  end
end
