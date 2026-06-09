defmodule Mobius.DataTest do
  use ExUnit.Case, async: false

  alias Mobius.{Data, DDSketch}

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

  describe "summary_windows/3" do
    @tag :tmp_dir
    test "returns flat per-window maps with average, std_dev and reports", %{tmp_dir: tmp_dir} do
      instance = :data_summary_windows

      start_instance(instance, tmp_dir, [
        Telemetry.Metrics.summary("db.query.ms", measurement: :ms)
      ])

      # Batch A then a couple of snapshots, then batch B and more snapshots so
      # at least one window lands between two stored cumulative snapshots.
      for n <- 1..10, do: :telemetry.execute([:db, :query], %{ms: n * 1.0}, %{})
      Process.sleep(@scrape_interval_ms * 2)

      for n <- 100..119, do: :telemetry.execute([:db, :query], %{ms: n * 1.0}, %{})
      Process.sleep(@scrape_interval_ms * 2)

      {:ok, windows} =
        Data.summary_windows("db.query.ms", %{}, mobius_instance: instance, last: {1, :hour})

      assert windows != []

      for w <- windows do
        assert is_integer(w.timestamp)
        assert is_float(w.average)
        assert is_number(w.std_dev)
        assert is_integer(w.reports) and w.reports > 0
      end

      # Ascending by timestamp.
      timestamps = Enum.map(windows, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)

      # The window covering batch B carries 20 reports and an average in B's range.
      b_window = Enum.find(windows, &(&1.reports == 20))
      assert b_window
      assert b_window.average >= 100.0 and b_window.average <= 119.0
    end

    @tag :tmp_dir
    test "windows are not truncated to the default 60-day retention", %{tmp_dir: tmp_dir} do
      instance = :data_summary_windows_no_cap

      start_instance(instance, tmp_dir, [
        Telemetry.Metrics.summary("db.query.ms", measurement: :ms)
      ])

      for n <- 1..10, do: :telemetry.execute([:db, :query], %{ms: n * 1.0}, %{})
      Process.sleep(@scrape_interval_ms * 2)

      for n <- 100..119, do: :telemetry.execute([:db, :query], %{ms: n * 1.0}, %{})
      Process.sleep(@scrape_interval_ms * 2)

      # The stored data lies more than 60 days before :to but inside the
      # requested window. A hardcoded 60-day cap would silently drop it.
      to = System.system_time(:second) + 61 * 86_400

      {:ok, windows} =
        Data.summary_windows("db.query.ms", %{}, mobius_instance: instance, from: 0, to: to)

      assert windows != []
    end

    @tag :tmp_dir
    test "an unobserved summary metric yields no windows", %{tmp_dir: tmp_dir} do
      instance = :data_summary_windows_empty

      start_instance(instance, tmp_dir, [
        Telemetry.Metrics.summary("never.summarized", measurement: :v)
      ])

      assert Data.summary_windows("never.summarized", %{}, mobius_instance: instance) ==
               {:ok, []}
    end
  end

  describe "metrics/4" do
    @tag :tmp_dir
    test "returns raw un-delta'd metric rows filtered by name/type/tags", %{tmp_dir: tmp_dir} do
      instance = :data_metrics_raw
      metrics = [Telemetry.Metrics.last_value("vm.memory.total", measurement: :total)]
      start_instance(instance, tmp_dir, metrics)

      :telemetry.execute([:vm, :memory], %{total: 100}, %{})
      Process.sleep(@scrape_interval_ms)
      :telemetry.execute([:vm, :memory], %{total: 110}, %{})
      Process.sleep(@scrape_interval_ms)

      assert {:ok, rows} =
               Data.metrics("vm.memory.total", :last_value, %{}, mobius_instance: instance)

      assert rows != []

      for row <- rows do
        assert row.name == "vm.memory.total"
        assert row.type == :last_value
        assert row.tags == %{}
        assert is_integer(row.timestamp)
        assert is_number(row.value)
      end

      # Raw, un-delta'd: the latest stored cumulative last_value is present.
      assert Enum.any?(rows, &(&1.value == 110))
    end

    @tag :tmp_dir
    test ":to alone bounds the result", %{tmp_dir: tmp_dir} do
      instance = :data_metrics_to_alone
      metrics = [Telemetry.Metrics.last_value("vm.memory.total", measurement: :total)]
      start_instance(instance, tmp_dir, metrics)

      :telemetry.execute([:vm, :memory], %{total: 100}, %{})
      Process.sleep(@scrape_interval_ms)

      # All stored data is newer than this :to, so nothing may come back. A
      # window resolution that ignores :to without :from would fall back to
      # the default last-3-minutes window and return the scraped row.
      before_data = System.system_time(:second) - 3600

      assert Data.metrics("vm.memory.total", :last_value, %{},
               mobius_instance: instance,
               to: before_data
             ) == {:ok, []}

      # And with :to in the future the row is included (from defaults to 0).
      assert {:ok, [_ | _]} =
               Data.metrics("vm.memory.total", :last_value, %{},
                 mobius_instance: instance,
                 to: System.system_time(:second) + 3600
               )
    end
  end

  describe "resolve_window/1" do
    test ":to without :from is honored, with :from defaulting to 0" do
      assert Data.resolve_window(to: 1_000) == {0, 1_000}
    end

    test ":from without :to runs to now" do
      now = System.system_time(:second)
      {from, to} = Data.resolve_window(from: 123)

      assert from == 123
      assert_in_delta to, now, 2
    end

    test ":from and :to are used as given" do
      assert Data.resolve_window(from: 100, to: 200) == {100, 200}
    end

    test "no window option defaults to the last 3 minutes" do
      now = System.system_time(:second)
      {from, to} = Data.resolve_window([])

      assert_in_delta to, now, 2
      assert to - from == 180
    end
  end

  describe "histogram/3" do
    @tag :tmp_dir
    test "reconstructs a DDSketch over the window", %{tmp_dir: tmp_dir} do
      instance = :data_histogram
      start_instance(instance, tmp_dir, [histogram_metric("http.request.duration", :duration)])

      for n <- 1..100, do: :telemetry.execute([:http, :request], %{duration: n * 1.0}, %{})
      Process.sleep(@scrape_interval_ms)

      assert {:ok, sketch} =
               Data.histogram("http.request.duration", %{}, mobius_instance: instance)

      assert %DDSketch{} = sketch
      assert DDSketch.total_count(sketch) == 100
    end

    @tag :tmp_dir
    test "surfaces the missing-metric error", %{tmp_dir: tmp_dir} do
      instance = :data_histogram_missing
      start_instance(instance, tmp_dir, [])

      assert {:error, {:no_histogram_metric, _}} =
               Data.histogram("does.not.exist", %{}, mobius_instance: instance)
    end
  end

  describe "unavailable instance" do
    test "queries return {:error, :unavailable} instead of exiting" do
      # No Mobius instance with this name is running — a raw GenServer.call
      # would exit with :noproc and take an unattended caller down with it.
      opts = [mobius_instance: :data_not_running]

      assert Data.summary_windows("db.query.ms", %{}, opts) == {:error, :unavailable}
      assert Data.metrics("vm.memory.total", :last_value, %{}, opts) == {:error, :unavailable}
      assert Data.histogram("http.request.duration", %{}, opts) == {:error, :unavailable}
      assert Data.quantile("http.request.duration", 0.5, %{}, opts) == {:error, :unavailable}

      assert Data.quantiles("http.request.duration", [0.5], %{}, opts) ==
               {:error, :unavailable}

      assert Data.count_below("http.request.duration", 100, %{}, opts) ==
               {:error, :unavailable}

      assert Data.count_above("http.request.duration", 100, %{}, opts) ==
               {:error, :unavailable}
    end
  end
end
