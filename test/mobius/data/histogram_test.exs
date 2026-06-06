defmodule Mobius.Data.HistogramTest do
  use ExUnit.Case, async: false

  alias Mobius.{Data, DDSketch}

  @scrape_interval_ms 1_100

  @tag :tmp_dir
  test "reconstructs a sketch from RRD snapshots and reports quantiles", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_basic

    metrics = [
      Telemetry.Metrics.summary("http.request.duration",
        measurement: :duration,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    # Observe a uniform spread of values.
    for n <- 1..100 do
      :telemetry.execute([:http, :request], %{duration: n * 1.0}, %{})
    end

    # Wait long enough for the scraper to capture an RRD snapshot.
    Process.sleep(@scrape_interval_ms)

    assert {:ok, sketch} =
             Data.histogram("http.request.duration", %{}, mobius_instance: instance)

    assert DDSketch.total_count(sketch) == 100

    {:ok, %{0.5 => p50, 0.95 => p95, 0.99 => p99}} =
      Data.quantiles("http.request.duration", [0.5, 0.95, 0.99], %{}, mobius_instance: instance)

    # Within ~2α of the true quantile of the input sequence.
    alpha = sketch.relative_accuracy
    assert_in_relative(p50, 50.0, 2 * alpha)
    assert_in_relative(p95, 95.0, 2 * alpha)
    assert_in_relative(p99, 99.0, 2 * alpha)
  end

  @tag :tmp_dir
  test "windowing: deltas reflect only observations inside the window", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_window

    metrics = [
      Telemetry.Metrics.summary("flash.write.duration",
        measurement: :duration,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    # Batch A: 10 fast writes.
    for n <- 1..10 do
      :telemetry.execute([:flash, :write], %{duration: n * 1.0}, %{})
    end

    # Wait long enough that ≥ 1 scrape captures batch A with a timestamp
    # strictly before window_start (whole-second resolution).
    Process.sleep(@scrape_interval_ms * 2)

    window_start = System.system_time(:second)

    # Batch B: 20 slower writes.
    for n <- 100..119 do
      :telemetry.execute([:flash, :write], %{duration: n * 1.0}, %{})
    end

    Process.sleep(@scrape_interval_ms * 2)
    window_end = System.system_time(:second)

    {:ok, window_sketch} =
      Data.histogram(
        "flash.write.duration",
        %{},
        mobius_instance: instance,
        from: window_start,
        to: window_end
      )

    # The window should contain ~ batch B only (20 observations).
    assert DDSketch.total_count(window_sketch) == 20
    alpha = window_sketch.relative_accuracy
    assert_in_relative(DDSketch.min(window_sketch), 100.0, alpha)
    assert_in_relative(DDSketch.max(window_sketch), 119.0, alpha)
  end

  @tag :tmp_dir
  test "count_below / count_above answer SLO-style questions", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_slo

    metrics = [
      Telemetry.Metrics.summary("mqtt.publish.ms",
        measurement: :ms,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    # 80 publishes under 100ms, 20 publishes over.
    for n <- 1..80, do: :telemetry.execute([:mqtt, :publish], %{ms: n * 1.0}, %{})
    for n <- 1..20, do: :telemetry.execute([:mqtt, :publish], %{ms: 200.0 + n}, %{})

    Process.sleep(@scrape_interval_ms)

    {:ok, fast} =
      Data.count_below("mqtt.publish.ms", 100, %{}, mobius_instance: instance)

    {:ok, slow} =
      Data.count_above("mqtt.publish.ms", 100, %{}, mobius_instance: instance)

    # The 100ms boundary may shift by up to α in bin terms; allow a small
    # tolerance.
    assert_in_delta(fast, 80, 3)
    assert_in_delta(slow, 20, 3)
    assert fast + slow == 100
  end

  @tag :tmp_dir
  test "missing metric returns a structured error", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_missing

    {:ok, _} =
      start_supervised({Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: []})

    assert {:error, {:no_histogram_metric, msg}} =
             Data.histogram("does.not.exist", %{}, mobius_instance: instance)

    assert msg =~ "no histogram-enabled metric"
  end

  @tag :tmp_dir
  test "non-histogram summary metric also returns the missing error", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_no_opt

    metrics = [
      Telemetry.Metrics.summary("plain.summary", measurement: :v)
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    assert {:error, {:no_histogram_metric, _}} =
             Data.histogram("plain.summary", %{}, mobius_instance: instance)
  end

  @tag :tmp_dir
  test "empty window returns an empty sketch", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_empty

    metrics = [
      Telemetry.Metrics.summary("never.observed",
        measurement: :v,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    {:ok, sketch} = Data.histogram("never.observed", %{}, mobius_instance: instance)
    assert DDSketch.empty?(sketch)
    assert DDSketch.quantile(sketch, 0.5) == nil
  end

  @tag :tmp_dir
  test "honors custom DDSketch relative_accuracy", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_custom_alpha

    metrics = [
      Telemetry.Metrics.summary("slow.thing.v",
        measurement: :v,
        reporter_options: [histogram: [relative_accuracy: 0.05, max_indexable_value: 1.0e9]]
      )
    ]

    {:ok, _} =
      start_supervised(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

    :telemetry.execute([:slow, :thing], %{v: 100.0}, %{})
    Process.sleep(@scrape_interval_ms)

    {:ok, sketch} = Data.histogram("slow.thing.v", %{}, mobius_instance: instance)
    assert sketch.relative_accuracy == 0.05
    assert DDSketch.total_count(sketch) == 1
  end

  @tag :tmp_dir
  test "histogram data survives a restart with unchanged config", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_restart_same

    metrics = [
      Telemetry.Metrics.summary("restart.same.duration",
        measurement: :duration,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    start_args = [mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics]
    {:ok, _} = start_supervised({Mobius, start_args})

    for n <- 1..50, do: :telemetry.execute([:restart, :same], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms)

    {:ok, sketch} = Data.histogram("restart.same.duration", %{}, mobius_instance: instance)
    assert DDSketch.total_count(sketch) == 50

    # Shut down (persists RRD and metrics table) and boot again unchanged.
    :ok = stop_supervised(Mobius)
    {:ok, _} = start_supervised({Mobius, start_args})
    Process.sleep(@scrape_interval_ms)

    {:ok, sketch} = Data.histogram("restart.same.duration", %{}, mobius_instance: instance)
    assert DDSketch.total_count(sketch) == 50
  end

  @tag :tmp_dir
  @tag capture_log: true
  test "histogram data is dropped when relative_accuracy changes across restart", %{
    tmp_dir: tmp_dir
  } do
    instance = :mobius_histogram_restart_changed

    metrics_for = fn histogram_opts ->
      [
        Telemetry.Metrics.summary("restart.changed.duration",
          measurement: :duration,
          reporter_options: [histogram: histogram_opts]
        )
      ]
    end

    {:ok, _} =
      start_supervised(
        {Mobius,
         mobius_instance: instance,
         persistence_dir: tmp_dir,
         metrics: metrics_for.(max_indexable_value: 1.0e9)}
      )

    for n <- 1..50, do: :telemetry.execute([:restart, :changed], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms)

    {:ok, sketch} = Data.histogram("restart.changed.duration", %{}, mobius_instance: instance)
    assert DDSketch.total_count(sketch) == 50

    # Restart with a different relative accuracy: the persisted bin indices
    # are meaningless under the new gamma, so both the RRD snapshots and the
    # restored live counters must be dropped.
    :ok = stop_supervised(Mobius)

    {:ok, _} =
      start_supervised(
        {Mobius,
         mobius_instance: instance,
         persistence_dir: tmp_dir,
         metrics: metrics_for.(max_indexable_value: 1.0e9, relative_accuracy: 0.05)}
      )

    for n <- 1..7, do: :telemetry.execute([:restart, :changed], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms)

    {:ok, sketch} = Data.histogram("restart.changed.duration", %{}, mobius_instance: instance)

    # Only the post-restart observations remain — not 57.
    assert DDSketch.total_count(sketch) == 7
    assert sketch.relative_accuracy == 0.05
  end

  @tag :tmp_dir
  @tag capture_log: true
  test "a counter reset inside the window degrades to since-reset counts", %{tmp_dir: tmp_dir} do
    instance = :mobius_histogram_reset

    metrics = [
      Telemetry.Metrics.summary("reset.case.duration",
        measurement: :duration,
        reporter_options: [histogram: [max_indexable_value: 1.0e9]]
      )
    ]

    start_args = [mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics]
    {:ok, _} = start_supervised({Mobius, start_args})

    for n <- 1..50, do: :telemetry.execute([:reset, :case], %{duration: n * 1.0}, %{})

    # Capture a pre-reset snapshot with a timestamp strictly before
    # window_start (whole-second resolution).
    Process.sleep(@scrape_interval_ms * 2)
    window_start = System.system_time(:second)

    # A reboot that loses the live counters while the snapshot history
    # survives: the metrics_table dump is gone, the RRD history is not.
    :ok = stop_supervised(Mobius)
    File.rm!(Path.join([tmp_dir, to_string(instance), "metrics_table"]))
    {:ok, _} = start_supervised({Mobius, start_args})

    for n <- 1..7, do: :telemetry.execute([:reset, :case], %{duration: n * 1.0}, %{})
    Process.sleep(@scrape_interval_ms * 2)
    window_end = System.system_time(:second)

    # The boundary snapshots straddle the reset: the baseline carries 50
    # cumulative observations, the window end only the 7 since the reboot.
    # The query degrades to everything observed since the reset instead of
    # crashing on the negative bin delta.
    assert {:ok, sketch} =
             Data.histogram(
               "reset.case.duration",
               %{},
               mobius_instance: instance,
               from: window_start,
               to: window_end
             )

    assert DDSketch.total_count(sketch) == 7
  end

  describe "build_window_sketch/7 baseline selection" do
    @key {"roll.off.metric", %{}}
    @opts [max_indexable_value: 1.0e9]

    test "no baseline and no roll-off: the metric started inside the window" do
      sketch =
        Data.Histogram.build_window_sketch(
          roll_off_snapshots(),
          false,
          "roll.off.metric",
          %{},
          @opts,
          50,
          250
        )

      assert DDSketch.total_count(sketch) == 25
    end

    test "no baseline after roll-off: the window truncates to retained history" do
      # The pre-window baseline rolled out of retention. The oldest retained
      # snapshot becomes the baseline, so only the observations after it are
      # attributed to the window — not the metric's entire cumulative history.
      sketch =
        Data.Histogram.build_window_sketch(
          roll_off_snapshots(),
          true,
          "roll.off.metric",
          %{},
          @opts,
          50,
          250
        )

      assert DDSketch.total_count(sketch) == 15
    end

    test "rolled off, but the metric is absent from the oldest scrape: it started inside retention" do
      snapshots = [{50, %{}} | roll_off_snapshots()]

      sketch =
        Data.Histogram.build_window_sketch(
          snapshots,
          true,
          "roll.off.metric",
          %{},
          @opts,
          60,
          250
        )

      assert DDSketch.total_count(sketch) == 25
    end

    test "an in-retention baseline wins regardless of roll-off" do
      sketch =
        Data.Histogram.build_window_sketch(
          roll_off_snapshots(),
          true,
          "roll.off.metric",
          %{},
          @opts,
          150,
          250
        )

      assert DDSketch.total_count(sketch) == 15
    end
  end

  # The metric's cumulative history: 10 observations of 10.0 by the first
  # snapshot, 15 more of 100.0 by the second.
  defp roll_off_snapshots() do
    [
      {100, %{@key => cumulative_snapshot(List.duplicate(10.0, 10))}},
      {200, %{@key => cumulative_snapshot(List.duplicate(10.0, 10) ++ List.duplicate(100.0, 15))}}
    ]
  end

  defp cumulative_snapshot(values) do
    sketch = Enum.reduce(values, DDSketch.new(@opts), &DDSketch.insert(&2, &1))
    :erlang.term_to_binary({sketch.positive_bins, sketch.negative_bins, sketch.zero_count})
  end

  defp assert_in_relative(actual, expected, tol) do
    err = abs(actual - expected) / abs(expected)

    assert err <= tol + 1.0e-9,
           "expected #{actual} within #{tol} of #{expected}, got relative error #{err}"
  end
end
