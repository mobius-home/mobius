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

    assert [{^metric_name, :summary, %{accumulated: 100, reports: 1}, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)

    :ok = MetricsTable.put(table, [:summary], :summary, 120)

    assert [{^metric_name, :summary, %{accumulated: 220, reports: 2}, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)
  end

  test "save/2 persists the table so init/1 can restore it" do
    persistence_dir =
      Path.join(System.tmp_dir!(), "mobius_save_roundtrip_#{System.unique_integer([:positive])}")

    File.mkdir_p!(persistence_dir)
    on_exit(fn -> File.rm_rf!(persistence_dir) end)

    table = :metrics_table_save_roundtrip
    ^table = MetricsTable.init(mobius_instance: table, persistence_dir: persistence_dir)

    :ok = MetricsTable.put(table, [:saved, :value], :last_value, 42)

    assert :ok = MetricsTable.save(table, persistence_dir)

    # The dump landed at the real path and no temp file was left behind.
    assert File.exists?(Path.join(persistence_dir, "metrics_table"))
    refute File.exists?(Path.join(persistence_dir, "metrics_table.tmp"))

    true = :ets.delete(table)

    ^table = MetricsTable.init(mobius_instance: table, persistence_dir: persistence_dir)

    assert [{"saved.value", :last_value, 42, %{}}] ==
             MetricsTable.get_entries_by_metric_name(table, "saved.value")
  end

  # Persisted metrics tables from older Mobius versions contain summary entries
  # with `:min` and `:max` keys. Loading those tables must still work — the
  # unused keys should be ignored and subsequent updates should produce the
  # current shape.
  test "restore persisted summary entry that contains legacy :min/:max keys" do
    persistence_dir =
      Path.join(System.tmp_dir!(), "mobius_legacy_summary_#{System.unique_integer([:positive])}")

    File.mkdir_p!(persistence_dir)
    on_exit(fn -> File.rm_rf!(persistence_dir) end)

    table = :metrics_table_legacy_restore
    :ets.new(table, [:named_table, :public, :set])

    key = {[:legacy, :summary], :summary, %{}}

    legacy_value = %{
      reports: 2,
      accumulated: 500,
      accumulated_sqrd: 170_000,
      min: 100,
      max: 400
    }

    :ets.insert(table, {key, legacy_value})

    :ok =
      :ets.tab2file(table, String.to_charlist(Path.join(persistence_dir, "metrics_table")))

    true = :ets.delete(table)

    ^table = MetricsTable.init(mobius_instance: table, persistence_dir: persistence_dir)

    metric_name = "legacy.summary"

    assert [{^metric_name, :summary, ^legacy_value, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)

    :ok = MetricsTable.put(table, [:legacy, :summary], :summary, 200)

    assert [
             {^metric_name, :summary, %{accumulated: 700, accumulated_sqrd: 210_000, reports: 3},
              %{}}
           ] =
             MetricsTable.get_entries_by_metric_name(table, metric_name)
  end
end
