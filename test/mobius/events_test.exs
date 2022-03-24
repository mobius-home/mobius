defmodule Mobius.EventsTest do
  use ExUnit.Case, async: true

  alias Mobius.{Events, MetricsTable}
  alias Telemetry.Metrics

  setup do
    table = :mobius_test_events
    MetricsTable.init(mobius_instance: table, persistence_dir: "/does/not/matter/here")

    {:ok, %{table: table}}
  end

  test "handles counter metric", %{table: table} do
    name = "events.test.count.me"

    config = %{
      table: table,
      metrics: [Metrics.counter("events.test.count.me")]
    }

    :ok = Events.handle([:events, :test, :count], %{}, %{}, config)

    assert [{^name, :counter, 1, %{}}] = MetricsTable.get_entries_by_metric_name(table, name)
  end

  test "handles last value metric", %{table: table} do
    name = "events.test.last.value"

    config = %{
      table: table,
      metrics: [Metrics.last_value("events.test.last.value")]
    }

    :ok = Events.handle([:events, :test, :last, :value], %{value: 1000}, %{}, config)

    assert [{^name, :last_value, 1000, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, name)
  end
end
