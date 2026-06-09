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

    config = Events.metric_handler_config(table, [Metrics.counter("events.test.count.me")])

    :ok = Events.handle_metrics([:events, :test, :count], %{}, %{}, config)

    assert [{^name, :counter, 1, %{}}] = MetricsTable.get_entries_by_metric_name(table, name)
  end

  test "handles last value metric", %{table: table} do
    name = "events.test.last.value"

    config = Events.metric_handler_config(table, [Metrics.last_value("events.test.last.value")])

    :ok = Events.handle_metrics([:events, :test, :last, :value], %{value: 1000}, %{}, config)

    assert [{^name, :last_value, 1000, %{}}] =
             MetricsTable.get_entries_by_metric_name(table, name)
  end

  describe "event handling" do
    @tag :tmp_dir
    test "basic event", %{tmp_dir: tmp_dir} do
      start_supervised!({Mobius, mobius_instance: :basic_event, persistence_dir: tmp_dir})

      config = %{
        table: :basic_event,
        event_opts: [],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1}, %{t: 1}, config)

      assert [event] = Mobius.EventLog.list(instance: :basic_event)

      assert event.name == "a.b.c"
      assert event.measurements == %{a: 1}
      assert event.tags == %{}
    end

    @tag :tmp_dir
    test "filter for tags", %{tmp_dir: tmp_dir} do
      start_supervised!({Mobius, mobius_instance: :filter_for_tags, persistence_dir: tmp_dir})

      config = %{
        table: :filter_for_tags,
        event_opts: [tags: [:t]],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1}, %{t: 1, z: 2}, config)

      assert [event] = Mobius.EventLog.list(instance: :filter_for_tags)

      assert event.name == "a.b.c"
      assert event.measurements == %{a: 1}
      assert event.tags == %{t: 1}
    end

    @tag :tmp_dir
    test "process measurements", %{tmp_dir: tmp_dir} do
      start_supervised!(
        {Mobius, mobius_instance: :process_measurements, persistence_dir: tmp_dir}
      )

      config = %{
        table: :process_measurements,
        event_opts: [tags: [:t], measurements_values: &event_measurement_processor/1],
        session: "test"
      }

      :ok = Events.handle_event("a.b.c", %{a: 1, b: 1}, %{t: 1, z: 2}, config)

      assert [event] = Mobius.EventLog.list(instance: :process_measurements)

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

  @histogram_table :mobius_test_histogram_metric

  describe "histogram-enabled summary metric" do
    setup do
      # A stable, compile-time table name. Tests in a module run sequentially
      # and the named ETS table is owned by the test process, so it is torn
      # down between tests and this literal is always free to (re)create.
      table = @histogram_table
      MetricsTable.init(mobius_instance: table, persistence_dir: "/does/not/matter/here")
      {:ok, %{table: table}}
    end

    test "writes both a summary and bin counters", %{table: table} do
      name = "hist.enabled.metric"

      metric =
        Metrics.summary(name,
          measurement: :latency,
          reporter_options: [histogram: [max_indexable_value: 1.0e9]]
        )

      config = Events.metric_handler_config(table, [metric])

      :ok = Events.handle_metrics([:hist, :enabled, :metric], %{latency: 1.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :enabled, :metric], %{latency: 50.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :enabled, :metric], %{latency: 100.0}, %{}, config)

      entries = MetricsTable.get_entries_by_metric_name(table, name)

      # summary row still present
      assert Enum.any?(entries, fn {_, type, _, _} -> type == :summary end)

      # at least one histogram bin row per distinct magnitude
      bin_entries = Enum.filter(entries, fn {_, type, _, _} -> match?({:hist, _, _}, type) end)
      assert length(bin_entries) >= 3

      total = Enum.sum(Enum.map(bin_entries, fn {_, _, count, _} -> count end))
      assert total == 3
    end

    test "respects custom DDSketch options", %{table: table} do
      name = "hist.custom.metric"

      metric =
        Metrics.summary(name,
          measurement: :latency,
          reporter_options: [histogram: [relative_accuracy: 0.005, max_indexable_value: 1.0e9]]
        )

      config = Events.metric_handler_config(table, [metric])

      :ok = Events.handle_metrics([:hist, :custom, :metric], %{latency: 10.0}, %{}, config)

      bin_entries =
        table
        |> MetricsTable.get_entries_by_metric_name(name)
        |> Enum.filter(fn {_, type, _, _} -> match?({:hist, _, _}, type) end)

      assert length(bin_entries) == 1

      [{_, {:hist, :pos, custom_idx}, _, _}] = bin_entries

      # Tighter α than the default — bin index should differ.
      default_sketch = Mobius.DDSketch.new(max_indexable_value: 1.0e9)
      {:hist, :pos, default_idx} = Mobius.DDSketch.bin_key_for_value(default_sketch, 10.0)
      assert custom_idx != default_idx
    end

    test "histogram is opt-in: a plain summary does not produce bin rows", %{table: table} do
      name = "hist.disabled.metric"

      metric = Metrics.summary(name, measurement: :latency)
      config = Events.metric_handler_config(table, [metric])

      :ok = Events.handle_metrics([:hist, :disabled, :metric], %{latency: 10.0}, %{}, config)

      bin_entries =
        table
        |> MetricsTable.get_entries_by_metric_name(name)
        |> Enum.filter(fn {_, type, _, _} -> match?({:hist, _, _}, type) end)

      assert bin_entries == []
    end

    test "over-max values clamp to the top bin (don't get dropped)", %{table: table} do
      name = "hist.clamp.metric"

      metric =
        Metrics.summary(name,
          measurement: :latency,
          reporter_options: [histogram: [max_indexable_value: 1000.0]]
        )

      config = Events.metric_handler_config(table, [metric])

      # Three values way above the cap, plus one inside it. With :clamp
      # (the default), all four are recorded; the three giants share the
      # top bin.
      :ok = Events.handle_metrics([:hist, :clamp, :metric], %{latency: 5_000.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :clamp, :metric], %{latency: 1_000_000.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :clamp, :metric], %{latency: 999_999.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :clamp, :metric], %{latency: 100.0}, %{}, config)

      bin_entries =
        table
        |> MetricsTable.get_entries_by_metric_name(name)
        |> Enum.filter(fn {_, type, _, _} -> match?({:hist, :pos, _}, type) end)

      assert length(bin_entries) == 2
      total = Enum.sum(Enum.map(bin_entries, fn {_, _, c, _} -> c end))
      assert total == 4
    end

    test ":on_overflow :drop silently skips over-max values", %{table: table} do
      name = "hist.drop.metric"

      metric =
        Metrics.summary(name,
          measurement: :latency,
          reporter_options: [histogram: [max_indexable_value: 1000.0, on_overflow: :drop]]
        )

      config = Events.metric_handler_config(table, [metric])

      :ok = Events.handle_metrics([:hist, :drop, :metric], %{latency: 5_000.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :drop, :metric], %{latency: 100.0}, %{}, config)

      bin_entries =
        table
        |> MetricsTable.get_entries_by_metric_name(name)
        |> Enum.filter(fn {_, type, _, _} -> match?({:hist, :pos, _}, type) end)

      total = Enum.sum(Enum.map(bin_entries, fn {_, _, c, _} -> c end))
      assert total == 1
    end

    test "negative values go to negative bins, near-zero into the zero bucket", %{table: table} do
      name = "hist.signed.metric"

      metric =
        Metrics.summary(name,
          measurement: :delta,
          reporter_options: [histogram: [min_indexable_value: 1.0e-3, max_indexable_value: 1.0e9]]
        )

      config = Events.metric_handler_config(table, [metric])

      :ok = Events.handle_metrics([:hist, :signed, :metric], %{delta: -100.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :signed, :metric], %{delta: 0.0}, %{}, config)
      :ok = Events.handle_metrics([:hist, :signed, :metric], %{delta: 1.0e-5}, %{}, config)
      :ok = Events.handle_metrics([:hist, :signed, :metric], %{delta: 100.0}, %{}, config)

      types =
        table
        |> MetricsTable.get_entries_by_metric_name(name)
        |> Enum.map(fn {_, type, _, _} -> type end)

      assert Enum.any?(types, &match?({:hist, :neg, _}, &1))
      assert Enum.any?(types, &match?({:hist, :pos, _}, &1))
      assert {:hist, :zero} in types
    end
  end
end
