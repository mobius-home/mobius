defmodule Mobius.Data do
  @moduledoc """
  Programmatic access to Mobius's stored metric data.

  This is the module to reach for when you want the *data itself* — to feed an
  alerting rule, a report, an SLO check, or any further computation. It is
  deliberately separate from the two neighbouring modules:

    * `Mobius.Charts` is for plotting and visualization. It returns shapes a
      renderer wants (sorted bars, one line per quantile, nested
      `%{timestamp:, value:}` points) and reports the resolved window so axes
      can be labelled. Reach for it when you are drawing a picture.
    * `Mobius.Exports` exists to serialize metric history into transport
      formats (CSV, the Mobius Binary Format). It will be removed or reworked;
      do not build new code on top of it.

  `Mobius.Data` is the new home for programmatic access. It returns plain,
  flat maps — no plotting envelope — with absolute second-resolution
  timestamps and raw numeric values:

    * `summary_windows/3` — per-window summary statistics, each window carrying
      `average`, `std_dev`, **and** `reports` (the number of observations that
      fell into that window).
    * `metrics/4` — the raw, un-delta'd rows of `t:Mobius.metric/0` for a metric
      over a window, filtered by name / type / tags.
    * `histogram/3` — the reconstructed `t:Mobius.DDSketch.t/0` for a histogram
      metric over a window.

  Every function accepts the same window options as `Mobius.Exports` and
  `Mobius.Charts` (`:last`, `:from`/`:to`, `:mobius_instance`); they resolve
  identically.
  """

  alias Mobius.{Exports, Scraper, Summary}

  @max_history_seconds 60 * 86_400

  @typedoc """
  Options shared by every query.

    * `:mobius_instance` - the instance to query (default `:mobius`)
    * `:last` - window covering the last `x`, where `x` is an integer number of
      seconds or `{integer(), Mobius.time_unit()}`
    * `:from` / `:to` - explicit unix-second window bounds

  With no window option the last 3 minutes are used.
  """
  @type opt() ::
          {:mobius_instance, Mobius.instance()}
          | {:from, integer()}
          | {:to, integer()}
          | {:last, integer() | {integer(), Mobius.time_unit()}}

  @typedoc """
  One window's summary statistics.

    * `:timestamp` - the absolute unix-second timestamp the window ends on
    * `:average` - the mean of the observations in the window
    * `:std_dev` - the standard deviation of the observations in the window
    * `:reports` - the number of observations that fell into the window
  """
  @type summary_window() :: %{
          timestamp: integer(),
          average: float(),
          std_dev: float(),
          reports: non_neg_integer()
        }

  @doc """
  Per-window summary statistics for a summary metric, ascending by timestamp.

  The stored summary record is a cumulative accumulator (sum / sum-of-squares /
  report count since the metric started), so the statistics for any one window
  are the *delta* between consecutive stored snapshots — the same idea
  `Mobius.DDSketch.delta/2` applies to histograms. Each returned map carries the
  `average`, `std_dev`, and `reports` (the subgroup size n) for just that
  window.

  A snapshot interval with no new reports contributes no entry, and an interval
  across which the cumulative counters reset (e.g. after a reboot) is skipped,
  so every entry reflects real observations rather than artifacts of a reset.

      Mobius.Data.summary_windows("http.request.duration", %{}, last: {1, :hour})
      # => [%{timestamp: 1_700_000_001, average: 12.4, std_dev: 3.1, reports: 18}, ...]
  """
  @spec summary_windows(Mobius.metric_name(), map(), [opt()]) :: [summary_window()]
  def summary_windows(metric_name, tags \\ %{}, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius
    {from, to} = resolve_window(opts)

    instance
    |> summary_deltas(metric_name, tags, from, to)
    |> Enum.map(fn {ts, delta} ->
      delta
      |> Summary.calculate()
      |> Map.put(:timestamp, ts)
    end)
  end

  @doc """
  The raw, un-delta'd metric rows for a metric over a window.

  Returns a list of `t:Mobius.metric/0` maps (`%{timestamp:, name:, type:,
  value:, tags:}`) — the stored data as captured at each scrape, with no
  windowing or delta arithmetic applied. Filtered by metric name, type, and
  tags.

  For the `:summary` type each row's `:value` is the cumulative
  `t:Mobius.Summary.t/0` map; for `{:summary, field}` it is that single field.
  This is the same data `Mobius.Exports.metrics/4` returns.

      Mobius.Data.metrics("vm.memory.total", :last_value, %{}, last: 30)
      # => [%{timestamp: ..., name: "vm.memory.total", type: :last_value, value: 51_200_000, tags: %{}}, ...]
  """
  @spec metrics(Mobius.metric_name(), Exports.export_metric_type(), map(), [opt()]) ::
          [Mobius.metric()]
  def metrics(metric_name, type, tags \\ %{}, opts \\ []) do
    Exports.Metrics.export(metric_name, type, tags, opts)
  end

  @doc """
  Reconstruct a `Mobius.DDSketch` histogram for a metric over a window.

  The metric must have been registered with histograms enabled
  (`reporter_options: [histogram: ...]`). Returns `{:ok, sketch}` where the
  sketch reflects the observations attributable to the window only, or
  `{:error, reason}` when the metric is not histogram-enabled.

      {:ok, sketch} = Mobius.Data.histogram("http.request.duration", %{}, last: {1, :hour})
      p95 = Mobius.DDSketch.quantile(sketch, 0.95)
  """
  @spec histogram(Mobius.metric_name(), map(), [opt()]) ::
          {:ok, Mobius.DDSketch.t()} | {:error, term()}
  def histogram(metric_name, tags \\ %{}, opts \\ []) do
    Exports.Histogram.histogram(metric_name, tags, opts)
  end

  # ----------------------------------------------------------------- helpers

  @doc false
  # Per-window summary deltas as `{end_ts, Summary.data()}` ascending. A summary
  # record is a cumulative accumulator (sum / sum² / report count since the
  # metric started), so each consecutive pair of snapshots yields the statistics
  # for just that window by subtraction. Pairs with no new reports are skipped,
  # and a negative report delta (the accumulator reset, e.g. after a reboot) is
  # skipped too.
  #
  # `Mobius.Charts.series/4` consumes this directly to build its summary line
  # points, so the windowing logic lives here, once.
  @spec summary_deltas(Mobius.instance(), Mobius.metric_name(), map(), integer(), integer()) ::
          [{integer(), Summary.data()}]
  def summary_deltas(instance, metric_name, tags, from, to) do
    instance
    |> Scraper.all()
    |> Enum.flat_map(fn
      {ts, {^metric_name, :summary, data, rec_tags}} when rec_tags == tags -> [{ts, data}]
      _ -> []
    end)
    |> Enum.filter(fn {ts, _data} -> to - ts <= @max_history_seconds and ts <= to end)
    |> Enum.uniq_by(fn {ts, _data} -> ts end)
    |> Enum.sort_by(fn {ts, _data} -> ts end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{_t0, earlier}, {t1, later}] when t1 >= from ->
        reports = later.reports - earlier.reports

        if reports > 0 do
          delta = %{
            accumulated: later.accumulated - earlier.accumulated,
            accumulated_sqrd: later.accumulated_sqrd - earlier.accumulated_sqrd,
            reports: reports
          }

          [{t1, delta}]
        else
          []
        end

      _pair ->
        []
    end)
  end

  defp resolve_window(opts) do
    now = System.system_time(:second)

    cond do
      opts[:from] != nil -> {opts[:from], opts[:to] || now}
      opts[:last] != nil -> {now - last_seconds(opts[:last]), now}
      true -> {now - 180, now}
    end
  end

  defp last_seconds({n, :second}), do: n
  defp last_seconds({n, :minute}), do: n * 60
  defp last_seconds({n, :hour}), do: n * 3600
  defp last_seconds({n, :day}), do: n * 86_400
  defp last_seconds(n) when is_integer(n), do: n
end
