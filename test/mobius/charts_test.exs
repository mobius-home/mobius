defmodule Mobius.ChartsTest do
  use ExUnit.Case, async: false

  alias Mobius.Charts

  @scrape_interval_ms 1_100

  defp start_instance(instance, tmp_dir, metrics) do
    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    :ok
  end

  defp histogram_metric(name, measurement) do
    Telemetry.Metrics.summary(name,
      measurement: measurement,
      reporter_options: [histogram: [max_indexable_value: 1.0e9]]
    )
  end

  @tag :tmp_dir
  test "distribution returns sorted bars and total count", %{tmp_dir: tmp_dir} do
    instance = :charts_distribution
    start_instance(instance, tmp_dir, [histogram_metric("http.request.duration", :duration)])

    for n <- 1..100 do
      :telemetry.execute([:http, :request], %{duration: n * 1.0}, %{})
    end

    Process.sleep(@scrape_interval_ms)

    assert {:ok, dist} =
             Charts.distribution("http.request.duration", %{}, mobius_instance: instance)

    assert dist.metric == "http.request.duration"
    assert dist.total_count == 100
    assert dist.window.from < dist.window.to

    # Bars are sorted ascending by value and their counts sum to the total.
    values = Enum.map(dist.bins, & &1.value)
    assert values == Enum.sort(values)
    assert Enum.sum(Enum.map(dist.bins, & &1.count)) == 100
    assert Enum.all?(dist.bins, &(&1.count > 0))
  end

  @tag :tmp_dir
  test "distribution surfaces the missing-metric error", %{tmp_dir: tmp_dir} do
    instance = :charts_distribution_missing
    start_instance(instance, tmp_dir, [])

    assert {:error, {:no_histogram_metric, _}} =
             Charts.distribution("does.not.exist", %{}, mobius_instance: instance)
  end

  @tag :tmp_dir
  test "distribution of an unobserved metric is empty", %{tmp_dir: tmp_dir} do
    instance = :charts_distribution_empty
    start_instance(instance, tmp_dir, [histogram_metric("never.seen", :v)])

    assert {:ok, dist} = Charts.distribution("never.seen", %{}, mobius_instance: instance)
    assert dist.total_count == 0
    assert dist.bins == []
  end

  @tag :tmp_dir
  test "quantiles_over_time yields one line per quantile with timestamped points",
       %{tmp_dir: tmp_dir} do
    instance = :charts_qot
    start_instance(instance, tmp_dir, [histogram_metric("flash.write.duration", :duration)])

    # First batch, then a snapshot, then a second batch and another snapshot so
    # at least one window interval lands between two stored snapshots.
    for n <- 1..10, do: :telemetry.execute([:flash, :write], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)

    for n <- 100..119, do: :telemetry.execute([:flash, :write], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)

    assert {:ok, qot} =
             Charts.quantiles_over_time(
               "flash.write.duration",
               [0.5, 0.95],
               %{},
               mobius_instance: instance,
               last: {1, :hour}
             )

    assert [%{quantile: 0.5} = p50_line, %{quantile: 0.95} = p95_line] = qot.lines

    # At least one window produced points.
    assert p50_line.points != []

    for point <- p50_line.points ++ p95_line.points do
      assert point.timestamp >= qot.window.from
      assert point.timestamp <= qot.window.to
      assert is_float(point.value)
    end

    # Points are ordered in time.
    timestamps = Enum.map(p50_line.points, & &1.timestamp)
    assert timestamps == Enum.sort(timestamps)
  end

  @tag :tmp_dir
  @tag capture_log: true
  test "quantiles_over_time skips the interval across a counter reset", %{tmp_dir: tmp_dir} do
    instance = :charts_qot_reset
    metrics = [histogram_metric("reset.write.duration", :duration)]
    start_args = [mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics]
    {:ok, _} = start_supervised({Mobius, start_args})

    for n <- 1..50, do: :telemetry.execute([:reset, :write], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)

    # A reboot that loses the live counters while the snapshot history
    # survives: the metrics_table dump is gone, the RRD history is not.
    :ok = stop_supervised(Mobius)
    File.rm!(Path.join([tmp_dir, to_string(instance), "metrics_table"]))
    {:ok, _} = start_supervised({Mobius, start_args})

    # Two post-reset batches so at least one clean post-reset interval
    # lands between two stored snapshots.
    for n <- 100..109, do: :telemetry.execute([:reset, :write], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)
    for n <- 110..119, do: :telemetry.execute([:reset, :write], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)

    # The pair straddling the reset is skipped rather than crashing the
    # whole query; clean intervals still produce points.
    assert {:ok, qot} =
             Charts.quantiles_over_time(
               "reset.write.duration",
               [0.5],
               %{},
               mobius_instance: instance,
               last: {1, :hour}
             )

    assert [%{quantile: 0.5, points: points}] = qot.lines
    assert points != []

    # Every surviving point comes from a clean interval — values reflect
    # real observations, never artifacts of the reset.
    for point <- points do
      assert point.value >= 1.0
      assert point.value <= 120.0
    end
  end

  @tag :tmp_dir
  test "quantiles_over_time surfaces the missing-metric error", %{tmp_dir: tmp_dir} do
    instance = :charts_qot_missing
    start_instance(instance, tmp_dir, [])

    assert {:error, {:no_histogram_metric, _}} =
             Charts.quantiles_over_time("nope", [0.5], %{}, mobius_instance: instance)
  end

  @tag :tmp_dir
  test "series returns timestamped points for a metric", %{tmp_dir: tmp_dir} do
    instance = :charts_series
    metrics = [Telemetry.Metrics.last_value("device.temp.celsius", measurement: :celsius)]
    start_instance(instance, tmp_dir, metrics)

    :telemetry.execute([:device, :temp], %{celsius: 41.0}, %{})
    Process.sleep(@scrape_interval_ms)
    :telemetry.execute([:device, :temp], %{celsius: 42.0}, %{})
    Process.sleep(@scrape_interval_ms)

    series = Charts.series("device.temp.celsius", :last_value, %{}, mobius_instance: instance)

    assert series.metric == "device.temp.celsius"
    assert series.type == :last_value
    assert series.window.from < series.window.to
    assert series.points != []
    assert Enum.all?(series.points, &(is_integer(&1.timestamp) and is_number(&1.value)))

    timestamps = Enum.map(series.points, & &1.timestamp)
    assert timestamps == Enum.sort(timestamps)
  end

  test "series returns {:error, :unavailable} when the instance is not running" do
    assert {:error, :unavailable} =
             Charts.series("some.metric", :last_value, %{},
               mobius_instance: :charts_not_running_test
             )
  end

  test "series returns {:error, :unavailable} for summary types when the instance is not running" do
    assert {:error, :unavailable} =
             Charts.series("some.metric", :summary, %{},
               mobius_instance: :charts_not_running_test
             )

    assert {:error, :unavailable} =
             Charts.series("some.metric", {:summary, :average}, %{},
               mobius_instance: :charts_not_running_test
             )
  end

  @tag :tmp_dir
  test "series rejects an unknown summary field", %{tmp_dir: tmp_dir} do
    instance = :charts_series_bad_field
    metrics = [Telemetry.Metrics.summary("http.request.duration", measurement: :duration)]
    start_instance(instance, tmp_dir, metrics)

    :telemetry.execute([:http, :request], %{duration: 12.0}, %{})
    Process.sleep(@scrape_interval_ms)

    assert {:error, {:invalid_summary_field, :p99}} =
             Charts.series("http.request.duration", {:summary, :p99}, %{},
               mobius_instance: instance
             )
  end

  @tag :tmp_dir
  test "latest returns the most recent value per metric and skips empty ones",
       %{tmp_dir: tmp_dir} do
    instance = :charts_latest

    metrics = [
      Telemetry.Metrics.last_value("vm.memory.total", measurement: :total),
      Telemetry.Metrics.last_value("vm.memory.processes", measurement: :processes)
    ]

    start_instance(instance, tmp_dir, metrics)

    :telemetry.execute([:vm, :memory], %{total: 100, processes: 40}, %{})
    Process.sleep(@scrape_interval_ms)
    :telemetry.execute([:vm, :memory], %{total: 110, processes: 45}, %{})
    Process.sleep(@scrape_interval_ms)

    result =
      Charts.latest(
        [
          {"vm.memory.total", :last_value},
          {"vm.memory.processes", :last_value},
          {"vm.memory.never", :last_value}
        ],
        mobius_instance: instance
      )

    # The never-observed metric is dropped; input order is otherwise preserved.
    assert [total, processes] = result
    assert total.metric == "vm.memory.total"
    assert total.value == 110
    assert is_integer(total.timestamp)
    assert processes.metric == "vm.memory.processes"
    assert processes.value == 45
  end
end
