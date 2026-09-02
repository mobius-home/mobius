defmodule Mobius.Data.ReadingsTest do
  use ExUnit.Case, async: true

  alias Mobius.{Data, DDSketch, Summary}
  alias Mobius.Data.Readings

  doctest Readings

  @sketch_opts [max_indexable_value: 1.0e6]
  @histogram_sketch_opts %{{"http.duration", []} => @sketch_opts}

  defp snap(ts, records, histograms \\ %{}), do: {ts, {records, histograms}}

  defp gauge(value, tags \\ %{}), do: {"vm.memory", :last_value, value, tags}
  defp counter(value, tags \\ %{}), do: {"http.requests", :counter, value, tags}
  defp sum(value, tags \\ %{}), do: {"net.tx_bytes", :sum, value, tags}
  defp summary(data), do: {"db.query", :summary, data, %{}}

  defp accumulate(values) do
    [first | rest] = values
    Enum.reduce(rest, Summary.new(first), &Summary.update(&2, &1))
  end

  defp accumulate(data, values), do: Enum.reduce(values, data, &Summary.update(&2, &1))

  # The at-rest payload of a sketch holding `values`, as the Scraper stores it.
  defp payload(values) do
    sketch = Enum.reduce(values, DDSketch.new(@sketch_opts), &DDSketch.insert(&2, &1))

    {pos, neg, zero} =
      Enum.reduce(DDSketch.bins(sketch), {%{}, %{}, 0}, fn
        {{:hist, :pos, idx}, count}, {pos, neg, zero} -> {Map.put(pos, idx, count), neg, zero}
        {{:hist, :neg, idx}, count}, {pos, neg, zero} -> {pos, Map.put(neg, idx, count), zero}
        {{:hist, :zero}, count}, {pos, neg, _zero} -> {pos, neg, count}
      end)

    :erlang.term_to_binary({pos, neg, zero})
  end

  defp metrics_at(readings, ts) do
    case Enum.find(readings, &(&1.timestamp == ts)) do
      nil -> nil
      reading -> reading.metrics
    end
  end

  describe "thinning" do
    test "keeps the earliest scrape of each step and drops the rest" do
      # A second per scrape for two minutes, the way the seconds archive looks.
      snapshots = for ts <- 0..119, do: snap(ts, [gauge(ts)])

      readings = Readings.build(snapshots, %{}, 0, 119, step: :minute)

      assert Enum.map(readings, & &1.timestamp) == [0, 60]
      assert metrics_at(readings, 0) == %{"vm.memory" => 0}
      assert metrics_at(readings, 60) == %{"vm.memory" => 60}
    end

    test "a step of :second keeps every scrape" do
      snapshots = for ts <- 0..9, do: snap(ts, [gauge(ts)])

      readings = Readings.build(snapshots, %{}, 0, 9, step: :second)

      assert length(readings) == 10
    end

    test "a step in seconds buckets accordingly" do
      snapshots = for ts <- 0..599, do: snap(ts, [gauge(ts)])

      readings = Readings.build(snapshots, %{}, 0, 599, step: 300)

      assert Enum.map(readings, & &1.timestamp) == [0, 300]
    end

    test "a window sparser than the step yields the scrapes that exist" do
      # Hourly scrapes, minutes asked for: no invention, no gaps filled.
      snapshots = for h <- 0..3, do: snap(h * 3_600, [gauge(h)])

      readings = Readings.build(snapshots, %{}, 0, 4 * 3_600, step: :minute)

      assert Enum.map(readings, & &1.timestamp) == [0, 3_600, 7_200, 10_800]
    end

    test "sorts unsorted input before thinning" do
      snapshots = [snap(61, [gauge(2)]), snap(0, [gauge(0)]), snap(60, [gauge(1)])]

      readings = Readings.build(snapshots, %{}, 0, 120, step: :minute)

      assert Enum.map(readings, & &1.timestamp) == [0, 60]
      assert metrics_at(readings, 60) == %{"vm.memory" => 1}
    end
  end

  describe "the window" do
    test "is inclusive on both ends" do
      snapshots = for m <- 0..5, do: snap(m * 60, [gauge(m)])

      readings = Readings.build(snapshots, %{}, 60, 180, step: :minute)

      assert Enum.map(readings, & &1.timestamp) == [60, 120, 180]
    end

    test "readings with nothing to say are left out" do
      # Only a counter, so the first scrape has no rate to report.
      snapshots = [snap(0, [counter(10)]), snap(60, [counter(70)])]

      readings = Readings.build(snapshots, %{}, 0, 60, step: :minute)

      assert Enum.map(readings, & &1.timestamp) == [60]
    end

    test "the scrape before the window is the baseline for the first reading" do
      snapshots = [snap(0, [counter(0)]), snap(60, [counter(120)]), snap(120, [counter(180)])]

      readings = Readings.build(snapshots, %{}, 60, 120, step: :minute)

      assert metrics_at(readings, 60) == %{"http.requests.rate" => 2.0}
      assert metrics_at(readings, 120) == %{"http.requests.rate" => 1.0}
    end
  end

  describe "last_value" do
    test "is carried as is" do
      readings = Readings.build([snap(0, [gauge(41.5)])], %{}, 0, 0)

      assert metrics_at(readings, 0) == %{"vm.memory" => 41.5}
    end

    test "that is not a number is dropped" do
      readings = Readings.build([snap(0, [gauge(:up), gauge(1, %{host: "a"})])], %{}, 0, 0)

      assert metrics_at(readings, 0) == %{"vm.memory.a" => 1}
    end
  end

  describe "counter and sum" do
    test "become the rate since the previous reading, per second by default" do
      snapshots = [snap(0, [counter(100), sum(0)]), snap(60, [counter(160), sum(6_000)])]

      readings = Readings.build(snapshots, %{}, 0, 60)

      assert metrics_at(readings, 60) == %{
               "http.requests.rate" => 1.0,
               "net.tx_bytes.rate" => 100.0
             }
    end

    test "honour :rate_unit" do
      snapshots = [snap(0, [counter(0)]), snap(60, [counter(60)])]

      assert [%{metrics: %{"http.requests.rate" => 60.0}}] =
               Readings.build(snapshots, %{}, 60, 60, rate_unit: :minute)

      assert [%{metrics: %{"http.requests.rate" => 3_600.0}}] =
               Readings.build(snapshots, %{}, 60, 60, rate_unit: :hour)
    end

    test "the rate uses the real elapsed time between the two readings" do
      # Hourly scrapes: the delta is an hour's worth, the rate is still per second.
      snapshots = [snap(0, [counter(0)]), snap(3_600, [counter(7_200)])]

      readings = Readings.build(snapshots, %{}, 0, 3_600, step: :minute)

      assert metrics_at(readings, 3_600) == %{"http.requests.rate" => 2.0}
    end

    test "report nothing across a reset" do
      snapshots = [snap(0, [counter(500)]), snap(60, [counter(3)]), snap(120, [counter(63)])]

      readings = Readings.build(snapshots, %{}, 0, 120)

      assert metrics_at(readings, 60) == nil
      assert metrics_at(readings, 120) == %{"http.requests.rate" => 1.0}
    end

    test "report nothing for a series that has just appeared" do
      snapshots = [
        snap(0, [gauge(1)]),
        snap(60, [gauge(1), counter(10)]),
        snap(120, [gauge(1), counter(70)])
      ]

      readings = Readings.build(snapshots, %{}, 0, 120)

      assert metrics_at(readings, 60) == %{"vm.memory" => 1}
      assert metrics_at(readings, 120) == %{"vm.memory" => 1, "http.requests.rate" => 1.0}
    end

    test "delta against the previous *reading*, not the previous scrape" do
      # Seconds archive: the counter grows by one a second. Thinned to
      # minutes the rate must still be 1/s, computed over the 60 s between
      # the two kept scrapes rather than the 1 s to the dropped neighbour.
      snapshots = for ts <- 0..120, do: snap(ts, [counter(ts)])

      readings = Readings.build(snapshots, %{}, 0, 120, step: :minute)

      assert metrics_at(readings, 60) == %{"http.requests.rate" => 1.0}
      assert metrics_at(readings, 120) == %{"http.requests.rate" => 1.0}
    end
  end

  describe "summary" do
    test "carries the statistics of the observations since the previous reading" do
      first = accumulate([1, 2, 3])
      second = accumulate(first, [100, 110, 120, 130])

      snapshots = [snap(0, [summary(first)]), snap(60, [summary(second)])]

      readings = Readings.build(snapshots, %{}, 0, 60)

      assert metrics_at(readings, 0) == nil

      assert %{
               "db.query.average" => 115.0,
               "db.query.reports" => 4,
               "db.query.std_dev" => std_dev
             } =
               metrics_at(readings, 60)

      assert_in_delta std_dev, 12.9, 0.1
    end

    test "reports nothing when there were no new observations, or after a reset" do
      data = accumulate([1, 2, 3])
      fresh = accumulate([9])

      snapshots = [
        snap(0, [summary(data)]),
        snap(60, [summary(data)]),
        snap(120, [summary(fresh)])
      ]

      readings = Readings.build(snapshots, %{}, 0, 120)

      assert readings == []
    end
  end

  describe "histograms" do
    test "carry the quantiles of the observations since the previous reading" do
      earlier = payload(Enum.to_list(1..50))
      later = payload(Enum.to_list(1..50) ++ Enum.to_list(1_000..1_099))

      snapshots = [
        snap(0, [], %{{"http.duration", %{}} => earlier}),
        snap(60, [], %{{"http.duration", %{}} => later})
      ]

      readings = Readings.build(snapshots, @histogram_sketch_opts, 0, 60)

      assert metrics_at(readings, 0) == nil

      assert %{"http.duration.p50" => p50, "http.duration.p95" => p95, "http.duration.p99" => p99} =
               metrics_at(readings, 60)

      # Only the later batch is this reading's; the 1..50 baseline is subtracted out.
      assert_in_delta p50, 1_050, 1_050 * 0.1
      assert_in_delta p95, 1_095, 1_095 * 0.1
      assert_in_delta p99, 1_099, 1_099 * 0.1
    end

    test "honour :quantiles" do
      snapshots = [
        snap(0, [], %{{"http.duration", %{}} => payload([1])}),
        snap(60, [], %{{"http.duration", %{}} => payload([1, 200, 300])})
      ]

      readings = Readings.build(snapshots, @histogram_sketch_opts, 60, 60, quantiles: [0.999])

      assert [%{metrics: %{"http.duration.p99.9" => _}}] = readings
    end

    test "report nothing without a baseline, across a reset, or for an unconfigured series" do
      snapshots = [
        snap(0, [], %{
          {"http.duration", %{}} => payload([1, 2, 3]),
          {"other", %{}} => payload([1])
        }),
        snap(60, [], %{{"http.duration", %{}} => payload([1]), {"other", %{}} => payload([1, 2])})
      ]

      assert Readings.build(snapshots, @histogram_sketch_opts, 0, 60) == []
    end

    test "sketch_opts_by_series/1 keys histogram-enabled definitions by name and tag keys" do
      metrics = [
        Telemetry.Metrics.summary("http.duration",
          tags: [:route, :method],
          reporter_options: [histogram: @sketch_opts]
        ),
        Telemetry.Metrics.summary("db.query", measurement: :ms),
        Telemetry.Metrics.last_value("vm.memory")
      ]

      assert Readings.sketch_opts_by_series(metrics) == %{
               {"http.duration", [:method, :route]} => @sketch_opts
             }
    end
  end

  describe "keys" do
    test "fold tags into the name, values sorted by tag key" do
      readings = Readings.build([snap(0, [gauge(1, %{ifname: "wlan0", host: :rpi})])], %{}, 0, 0)

      assert metrics_at(readings, 0) == %{"vm.memory.rpi.wlan0" => 1}
    end

    test "a :key function renames and, returning nil, drops" do
      key = fn
        "vm.memory", %{}, nil -> "mem_total"
        _name, _tags, _field -> nil
      end

      snapshots = [snap(0, [gauge(1), counter(0)]), snap(60, [gauge(2), counter(60)])]

      readings = Readings.build(snapshots, %{}, 0, 60, key: key)

      assert Enum.map(readings, & &1.metrics) == [%{"mem_total" => 1}, %{"mem_total" => 2}]
    end
  end

  describe "Mobius.Data.readings/1" do
    @tag :tmp_dir
    test "reads a live instance", %{tmp_dir: tmp_dir} do
      instance = :data_readings_live

      metrics = [
        Telemetry.Metrics.last_value("readings.gauge.value"),
        Telemetry.Metrics.counter("readings.hits.count")
      ]

      start_supervised!(
        {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: metrics}
      )

      :telemetry.execute([:readings, :gauge], %{value: 7}, %{})
      :telemetry.execute([:readings, :hits], %{count: 1}, %{})
      Process.sleep(1_200)
      :telemetry.execute([:readings, :hits], %{count: 1}, %{})
      Process.sleep(1_200)

      assert {:ok, readings} =
               Data.readings(mobius_instance: instance, step: :second, last: {1, :minute})

      assert readings != []
      assert Enum.all?(readings, &(&1.metrics["readings.gauge.value"] == 7))
      assert Enum.any?(readings, &(Map.get(&1.metrics, "readings.hits.count.rate", 0) > 0))
    end

    test "is unavailable rather than a crash when the instance is not running" do
      assert Data.readings(mobius_instance: :no_such_instance) == {:error, :unavailable}
    end
  end
end
