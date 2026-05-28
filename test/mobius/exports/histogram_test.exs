defmodule Mobius.Exports.HistogramTest do
  use ExUnit.Case, async: false

  alias Mobius.{DDSketch, Exports}

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
             Exports.histogram("http.request.duration", %{}, mobius_instance: instance)

    assert DDSketch.total_count(sketch) == 100

    {:ok, %{0.5 => p50, 0.95 => p95, 0.99 => p99}} =
      Exports.quantiles("http.request.duration", [0.5, 0.95, 0.99], %{},
        mobius_instance: instance
      )

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
      Exports.histogram(
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
      Exports.histogram_count_below("mqtt.publish.ms", 100, %{}, mobius_instance: instance)

    {:ok, slow} =
      Exports.histogram_count_above("mqtt.publish.ms", 100, %{}, mobius_instance: instance)

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
             Exports.histogram("does.not.exist", %{}, mobius_instance: instance)

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
             Exports.histogram("plain.summary", %{}, mobius_instance: instance)
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

    {:ok, sketch} = Exports.histogram("never.observed", %{}, mobius_instance: instance)
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

    {:ok, sketch} = Exports.histogram("slow.thing.v", %{}, mobius_instance: instance)
    assert sketch.relative_accuracy == 0.05
    assert DDSketch.total_count(sketch) == 1
  end

  defp assert_in_relative(actual, expected, tol) do
    err = abs(actual - expected) / abs(expected)

    assert err <= tol + 1.0e-9,
           "expected #{actual} within #{tol} of #{expected}, got relative error #{err}"
  end
end
