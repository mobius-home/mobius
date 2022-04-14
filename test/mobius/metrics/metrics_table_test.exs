defmodule Mobius.Metrics.MetricsTableTest do
  use ExUnit.Case, async: true

  alias Mobius.MetricsTable

  setup do
    table_name = :metrics_table_test_table
    MetricsTable.init(mobius_instance: table_name, persistence_dir: "/does/not/matter/here")

    {:ok, %{table: table_name}}
  end

  test "initialize counter on first update", %{table: table} do
    :ok = MetricsTable.put(table, [:counter, :event, :hello], :counter, 1)

    result = MetricsTable.get_entries_by_metric_name(table, "counter.event.hello")

    assert result == [{"counter.event.hello", :counter, 1, %{}}]
  end

  test "increment counter after first report", %{table: table} do
    :ok = MetricsTable.put(table, [:counter, :event, :world], :counter, 1)
    :ok = MetricsTable.put(table, [:counter, :event, :world], :counter, 1)

    result = MetricsTable.get_entries_by_metric_name(table, "counter.event.world")

    assert result == [{"counter.event.world", :counter, 2, %{}}]
  end

  test "increment counter with inc_counter/3", %{table: table} do
    metric_name = "increment.helper.event"

    Enum.each(0..2, fn _ ->
      :ok = MetricsTable.inc_counter(table, [:increment, :helper, :event])
    end)

    result = MetricsTable.get_entries_by_metric_name(table, metric_name)

    assert result == [{metric_name, :counter, 3, %{}}]
  end

  test "initialize last value on first report", %{table: table} do
    metric_name = "last.value.event.one"

    :ok = MetricsTable.put(table, [:last, :value, :event, :one], :last_value, 123)

    result = MetricsTable.get_entries_by_metric_name(table, metric_name)

    assert result == [{metric_name, :last_value, 123, %{}}]
  end

  test "update last value after first report", %{table: table} do
    metric_name = "last.value.event.two"

    :ok = MetricsTable.put(table, [:last, :value, :event, :two], :last_value, 321)
    :ok = MetricsTable.put(table, [:last, :value, :event, :two], :last_value, 765)

    result = MetricsTable.get_entries_by_metric_name(table, metric_name)

    assert result == [{metric_name, :last_value, 765, %{}}]
  end

  test "remove a metric from the metric table", %{table: table} do
    metric_name = "i.will.be.removed"
    :ok = MetricsTable.put(table, [:i, :will, :be, :removed], :last_value, 1000)

    # ensure the metric is saved
    assert [{metric_name, :last_value, 1000, %{}}] ==
             MetricsTable.get_entries_by_metric_name(table, metric_name)

    :ok = MetricsTable.remove(table, [:i, :will, :be, :removed], :last_value)

    # make sure removed
    assert [] == MetricsTable.get_entries_by_metric_name(table, metric_name)
  end

  test "update a sum of values", %{table: table} do
    metric_name = "sum"
    :ok = MetricsTable.update_sum(table, [:sum], 100)

    assert [{metric_name, :sum, 100, %{}}] ==
             MetricsTable.get_entries_by_metric_name(table, metric_name)

    :ok = MetricsTable.update_sum(table, [:sum], 50)

    assert [{metric_name, :sum, 150, %{}}] ==
             MetricsTable.get_entries_by_metric_name(table, metric_name)
  end

  test "handle summary telemetry", %{table: table} do
    metric_name = "summary"
    :ok = MetricsTable.put(table, [:summary], :summary, 100)

    assert [{^metric_name, :summary, %{accumulated: 100, max: 100, min: 100, reports: 1}, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)

    :ok = MetricsTable.put(table, [:summary], :summary, 120)

    assert [{^metric_name, :summary, %{accumulated: 220, max: 120, min: 100, reports: 2}, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)
  end
end
