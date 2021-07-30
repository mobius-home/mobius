defmodule Mobius.EventsTest do
  use ExUnit.Case, async: true

  alias Mobius.{Events, MetricsTable}
  alias Telemetry.Metrics

  setup do
    table = :mobius_test_events
    MetricsTable.init(name: table, persistence_dir: "/does/not/matter/here")

    {:ok, %{table: table}}
  end

  test "handles counter metric", %{table: table} do
    name = "events.test.count.me"
    normalized_name = normalize_metric_name(name)

    config = %{
      table: table,
      metrics: [Metrics.counter("events.test.count.me")]
    }

    :ok = Events.handle(Enum.take(normalized_name, 3), %{}, %{}, config)

    assert [{^normalized_name, :counter, 1, %{}}] =
             MetricsTable.get_entries_by_event_name(table, normalized_name)
  end

  test "handles last value metric", %{table: table} do
    name = "events.test.last.value"
    normalized_name = normalize_metric_name(name)

    config = %{
      table: table,
      metrics: [Metrics.last_value("events.test.last.value")]
    }

    :ok = Events.handle(Enum.take(normalized_name, 3), %{value: 1000}, %{}, config)

    assert [{^normalized_name, :last_value, 1000, %{}}] =
             MetricsTable.get_entries_by_event_name(table, normalized_name)
  end

  defp normalize_metric_name(metric_name) do
    metric_name
    |> String.split(".", trim: true)
    |> Enum.map(&String.to_atom/1)
  end
end
