defmodule Mobius.InfoTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @persistence_dir System.tmp_dir!() |> Path.join("mobius_info_test")
  @instance :mobius

  setup do
    File.rm_rf!(@persistence_dir)
    File.mkdir_p(@persistence_dir)

    :ok
  end

  test "prints metrics for a plain counter" do
    metrics = [
      Telemetry.Metrics.counter("info.plain.count", event_name: [:info, :plain])
    ]

    {:ok, _pid} =
      start_supervised({Mobius, persistence_dir: @persistence_dir, metrics: metrics})

    :telemetry.execute([:info, :plain], %{count: 1}, %{})

    output = capture_io(fn -> assert :ok = Mobius.info(@instance) end)

    assert output =~ "Metric Name: info.plain.count"
    assert output =~ "counter: 1"
  end

  test "does not crash when a histogram-enabled metric has data" do
    metrics = [
      Telemetry.Metrics.summary("info.hist.duration",
        event_name: [:info, :hist],
        measurement: :duration,
        reporter_options: [histogram: true]
      )
    ]

    {:ok, _pid} =
      start_supervised({Mobius, persistence_dir: @persistence_dir, metrics: metrics})

    :telemetry.execute([:info, :hist], %{duration: 12.5}, %{})

    # The recorded value produced histogram bin rows with tuple types
    entries = Mobius.MetricsTable.get_entries_by_metric_name(@instance, "info.hist.duration")
    assert Enum.any?(entries, fn {_, type, _, _} -> match?({:hist, _, _}, type) end)

    output = capture_io(fn -> assert :ok = Mobius.info(@instance) end)

    assert output =~ "Metric Name: info.hist.duration"
    assert output =~ "summary:"
    refute output =~ "{:hist"
  end
end
