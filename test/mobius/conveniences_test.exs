defmodule Mobius.ConveniencesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @scrape_interval_ms 1_100

  defp start_instance(instance, tmp_dir, metrics) do
    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    :ok
  end

  defp last_value_metric(name, measurement) do
    Telemetry.Metrics.last_value(name, measurement: measurement)
  end

  defp histogram_metric(name, measurement) do
    Telemetry.Metrics.summary(name,
      measurement: measurement,
      reporter_options: [histogram: [max_indexable_value: 1.0e9]]
    )
  end

  @tag :tmp_dir
  test "metrics/1 lists the tracked metrics and flags histograms", %{tmp_dir: tmp_dir} do
    instance = :conv_metrics

    start_instance(instance, tmp_dir, [
      last_value_metric("vm.memory.total", :total),
      histogram_metric("http.request.duration", :duration)
    ])

    output = capture_io(fn -> assert :ok = Mobius.metrics(instance) end)

    assert output =~ "vm.memory.total"
    assert output =~ "last_value"
    assert output =~ "http.request.duration"
    assert output =~ "(histogram)"
  end

  @tag :tmp_dir
  test "metrics/1 says so when nothing is tracked", %{tmp_dir: tmp_dir} do
    instance = :conv_metrics_empty
    start_instance(instance, tmp_dir, [])

    output = capture_io(fn -> assert :ok = Mobius.metrics(instance) end)
    assert output =~ "No metrics are being tracked"
  end

  @tag :tmp_dir
  test "current/2 prints the latest value of a metric", %{tmp_dir: tmp_dir} do
    instance = :conv_current
    start_instance(instance, tmp_dir, [last_value_metric("vm.memory.total", :total)])

    :telemetry.execute([:vm, :memory], %{total: 12_345}, %{})
    Process.sleep(@scrape_interval_ms)

    output =
      capture_io(fn ->
        assert :ok = Mobius.current("vm.memory.total", mobius_instance: instance)
      end)

    assert output =~ "vm.memory.total"
    assert output =~ "12345"
  end

  @tag :tmp_dir
  test "current/2 prints a bucket histogram for histogram metrics", %{tmp_dir: tmp_dir} do
    instance = :conv_current_hist
    start_instance(instance, tmp_dir, [histogram_metric("http.request.duration", :duration)])

    for n <- 1..100, do: :telemetry.execute([:http, :request], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms)

    output =
      capture_io(fn ->
        assert :ok = Mobius.current("http.request.duration", mobius_instance: instance)
      end)

    assert output =~ "http.request.duration"
    # The histogram bars use full-block characters.
    assert output =~ "█"
  end

  @tag :tmp_dir
  test "current/2 reports an unknown metric helpfully", %{tmp_dir: tmp_dir} do
    instance = :conv_current_unknown
    start_instance(instance, tmp_dir, [])

    output =
      capture_io(fn ->
        assert :ok = Mobius.current("does.not.exist", mobius_instance: instance)
      end)

    assert output =~ "No metric named"
  end

  @tag :tmp_dir
  test "plot/2 renders a chart with axes for a tracked metric", %{tmp_dir: tmp_dir} do
    instance = :conv_plot
    start_instance(instance, tmp_dir, [last_value_metric("vm.memory.total", :total)])

    :telemetry.execute([:vm, :memory], %{total: 100}, %{})
    Process.sleep(@scrape_interval_ms)
    :telemetry.execute([:vm, :memory], %{total: 200}, %{})
    Process.sleep(@scrape_interval_ms)

    output =
      capture_io(fn ->
        assert :ok = Mobius.plot("vm.memory.total", mobius_instance: instance)
      end)

    assert output =~ "vm.memory.total"
    assert output =~ "┤"
    assert output =~ "└"
  end

  @tag :tmp_dir
  test "plot/2 refuses to plot a bare summary metric", %{tmp_dir: tmp_dir} do
    instance = :conv_plot_summary
    start_instance(instance, tmp_dir, [histogram_metric("http.request.duration", :duration)])

    output =
      capture_io(fn ->
        assert :ok = Mobius.plot("http.request.duration", mobius_instance: instance)
      end)

    assert output =~ "not plottable"
  end
end
