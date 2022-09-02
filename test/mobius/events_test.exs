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

    :ok = Events.handle_metrics([:events, :test, :count], %{}, %{}, config)

    assert [{^name, :counter, 1, %{}}] = MetricsTable.get_entries_by_metric_name(table, name)
  end

  test "handles last value metric", %{table: table} do
    name = "events.test.last.value"

    config = %{
      table: table,
      metrics: [Metrics.last_value("events.test.last.value")]
    }

    :ok = Events.handle_metrics([:events, :test, :last, :value], %{value: 1000}, %{}, config)

    assert [{^name, :last_value, 1000, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, name)
  end

  describe "event handling" do
    test "basic event" do
      start_supervised!(
        {Mobius, mobius_instance: :basic_event, persistence_dir: "/tmp/mobius_event_log"}
      )

      config = %{
        table: :basic_event,
        event_opts: [],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1}, %{t: 1}, config)

      assert [event] = Mobius.EventLog.list(:basic_event)

      assert event.name == "a.b.c"
      assert event.measurements == %{a: 1}
      assert event.tags == %{}
    end

    test "filter for tags" do
      start_supervised!(
        {Mobius, mobius_instance: :filter_for_tags, persistence_dir: "/tmp/mobius_event_log"}
      )

      config = %{
        table: :filter_for_tags,
        event_opts: [tags: [:t]],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1}, %{t: 1, z: 2}, config)

      assert [event] = Mobius.EventLog.list(:filter_for_tags)

      assert event.name == "a.b.c"
      assert event.measurements == %{a: 1}
      assert event.tags == %{t: 1}
    end

    test "process measurements" do
      start_supervised!(
        {Mobius, mobius_instance: :process_measurements, persistence_dir: "/tmp/mobius_event_log"}
      )

      config = %{
        table: :process_measurements,
        event_opts: [tags: [:t], measurements_values: &event_measurement_processor/1],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1, b: 1}, %{t: 1, z: 2}, config)

      assert [event] = Mobius.EventLog.list(:process_measurements)

      assert event.name == "a.b.c"
      assert event.measurements == %{a: 2, b: 1}
      assert event.tags == %{t: 1}
    end
  end

  defp event_measurement_processor({:a, n}) do
    n + 1
  end

  defp event_measurement_processor({_, value}) do
    value
  end
end
