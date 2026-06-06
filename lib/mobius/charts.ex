defmodule Mobius.Charts do
  @moduledoc """
  Query-ready data structures for graphing Mobius metrics.

  `Mobius.Data` returns the raw building blocks — a reconstructed
  `Mobius.DDSketch`, a flat list of metric points, a per-quantile map. Turning
  those into the shapes a chart actually wants (sorted histogram bars, a line
  per quantile over time, the latest value per metric) is the same handful of
  transforms re-written at every call site. This module does those transforms
  once and hands back plain, well-typed maps.

  Nothing here is tied to a particular renderer. Every function returns plain
  maps and lists with absolute second-resolution timestamps and raw numeric
  values; mapping those onto VegaLite, an ASCII chart, JSON, or anything else
  is the caller's job and is a trivial `Enum.map/2`.

  Four shapes, one per common query:

    * `distribution/3` — a histogram's bins as sorted `{value, count}` bars
      (`t:distribution/0`).
    * `quantiles_over_time/4` — one line of `{timestamp, value}` points per
      requested quantile (`t:quantiles_over_time/0`).
    * `series/4` — a single metric's values over time as `{timestamp, value}`
      points (`t:series/0`). Works for any metric type, including
      `{:summary, :average}` for an average-over-time line.
    * `latest/2` — the most recent value for a set of metrics
      (`t:latest_value/0`).

  All four accept the same window options as `Mobius.Exports` (`:last`,
  `:from`/`:to`, `:mobius_instance`) and report the resolved absolute window
  back in the result so a caller can label axes without re-deriving it.
  """

  alias Mobius.{Data, DDSketch, Exports, Scraper, Summary}

  @default_window_seconds 180
  @max_history_seconds 60 * 86_400

  @typedoc """
  Options shared by every query, identical to `t:Mobius.Exports.export_opt/0`.

    * `:mobius_instance` - the instance to query (default `:mobius`)
    * `:last` - window covering the last `x`, where `x` is an integer number of
      seconds or `{integer(), Mobius.time_unit()}`
    * `:from` / `:to` - explicit unix-second window bounds

  With no window option the last #{@default_window_seconds} seconds are used.
  """
  @type opt() ::
          {:mobius_instance, Mobius.instance()}
          | {:from, integer()}
          | {:to, integer()}
          | {:last, integer() | {integer(), Mobius.time_unit()}}

  @typedoc """
  The absolute window a result covers, as resolved unix-second bounds.
  """
  @type window() :: %{from: integer(), to: integer()}

  @typedoc """
  One histogram bar: the bin's representative value and its observation count.

  `value` is the DDSketch bin estimator — the same value `Mobius.DDSketch.quantile/2`
  reports for a value that lands in the bin. Bins are spaced geometrically, so
  treat `value` as an ordered category rather than a linear coordinate when
  plotting.
  """
  @type bin() :: %{value: float(), count: pos_integer()}

  @typedoc """
  A metric's distribution over a window: the histogram bars plus context.

    * `:metric` / `:tags` - what was queried
    * `:window` - the resolved time window
    * `:total_count` - total observations across all bins
    * `:bins` - bars sorted ascending by `value`; empty when nothing was observed
  """
  @type distribution() :: %{
          metric: Mobius.metric_name(),
          tags: map(),
          window: window(),
          total_count: non_neg_integer(),
          bins: [bin()]
        }

  @typedoc """
  One point on a time line: a value at an absolute second-resolution timestamp.
  """
  @type point() :: %{timestamp: integer(), value: number()}

  @typedoc """
  One quantile's line over time.

  `quantile` is the requested fraction in `[0.0, 1.0]`; `points` are sorted
  ascending by timestamp. Windows with no observations contribute no point, so
  a sparse metric yields a shorter line rather than gaps of `nil`.
  """
  @type quantile_line() :: %{quantile: float(), points: [point()]}

  @typedoc """
  Quantiles of a histogram metric tracked over a window.

  Each requested quantile becomes its own `t:quantile_line/0`, in the order the
  quantiles were requested — ready to draw as one line per series. The window is
  divided at the resolution Mobius actually stored (one point per stored
  snapshot interval).
  """
  @type quantiles_over_time() :: %{
          metric: Mobius.metric_name(),
          tags: map(),
          window: window(),
          lines: [quantile_line()]
        }

  @typedoc """
  A single metric's values over time.
  """
  @type series() :: %{
          metric: Mobius.metric_name(),
          type: Exports.export_metric_type(),
          tags: map(),
          window: window(),
          points: [point()]
        }

  @typedoc """
  A metric to request a latest value for: `{name, type, tags}`.
  """
  @type metric_ref() ::
          {Mobius.metric_name(), Exports.export_metric_type()}
          | {Mobius.metric_name(), Exports.export_metric_type(), map()}

  @typedoc """
  The most recent stored value for one metric.
  """
  @type latest_value() :: %{
          metric: Mobius.metric_name(),
          type: Exports.export_metric_type(),
          tags: map(),
          value: number(),
          timestamp: integer()
        }

  @doc """
  Project a histogram metric's distribution over a window into sorted bars.

  The metric must have been registered with histograms enabled
  (`reporter_options: [histogram: ...]`). Returns `{:error, reason}` from
  `Mobius.Data.histogram/3` when it is not.

      {:ok, dist} = Mobius.Charts.distribution("http.request.duration", %{}, last: {1, :hour})
      # dist.bins => [%{value: 9.8, count: 412}, %{value: 11.0, count: 380}, ...]

  Plotting then needs no math — map `:value`/`:count` straight onto x/y.
  """
  @spec distribution(Mobius.metric_name(), map(), [opt()]) ::
          {:ok, distribution()} | {:error, term()}
  def distribution(metric_name, tags \\ %{}, opts \\ []) do
    {from, to} = resolve_window(opts)
    window_opts = Keyword.merge(opts, from: from, to: to)

    with {:ok, sketch} <- Data.histogram(metric_name, tags, window_opts) do
      {:ok,
       %{
         metric: metric_name,
         tags: tags,
         window: %{from: from, to: to},
         total_count: DDSketch.total_count(sketch),
         bins: bars(sketch)
       }}
    end
  end

  @doc """
  Track quantiles of a histogram metric across a window, one line per quantile.

  `quantiles` is a list of fractions in `[0.0, 1.0]`. The window is split at the
  resolution Mobius stored — each stored snapshot interval becomes one point,
  carrying only the observations attributable to that interval. Windows with no
  observations are skipped, so a quiet stretch shortens the line rather than
  drawing a zero.

      {:ok, qot} =
        Mobius.Charts.quantiles_over_time("http.request.duration", [0.5, 0.95, 0.99], %{},
          last: {1, :hour}
        )

      for line <- qot.lines do
        # line.quantile => 0.95, line.points => [%{timestamp: ..., value: ...}, ...]
      end
  """
  @spec quantiles_over_time(Mobius.metric_name(), [float()], map(), [opt()]) ::
          {:ok, quantiles_over_time()} | {:error, term()}
  def quantiles_over_time(metric_name, quantiles, tags \\ %{}, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius
    {from, to} = resolve_window(opts)

    # A single histogram query both validates the metric (returning the nice
    # structured error if it is not histogram-enabled) and hands us a sketch
    # whose configuration we reuse to reconstruct every window's sketch.
    with {:ok, probe} <-
           Data.histogram(metric_name, tags, Keyword.merge(opts, from: from, to: to)) do
      sketch_opts = sketch_opts(probe)
      key = {metric_name, tags}

      windows = window_sketches(instance, key, sketch_opts, from, to)
      lines = Enum.map(quantiles, fn q -> %{quantile: q, points: quantile_points(windows, q)} end)

      {:ok,
       %{
         metric: metric_name,
         tags: tags,
         window: %{from: from, to: to},
         lines: lines
       }}
    end
  end

  @doc """
  A single metric's values over time as `{timestamp, value}` points.

  Accepts any `t:Mobius.Exports.export_metric_type/0`. Use a plain type
  (`:last_value`, `:counter`, `:sum`) for a gauge or counter line, or
  `{:summary, :average}` / `{:summary, :std_dev}` / `{:summary, :reports}`
  for a summary metric (plain `:summary` gives the full per-interval
  `%{average:, std_dev:, reports:}` map, where `reports` is the subgroup
  size n for that interval).

  Summary statistics are **per interval**: the stored summary is a cumulative
  accumulator (sum / sum-of-squares / count since the metric started), so each
  point is computed from the *delta* between consecutive stored snapshots —
  the same idea `DDSketch.delta/2` applies to histograms. A snapshot interval
  with no new reports contributes no point.

      avg = Mobius.Charts.series("http.request.duration", {:summary, :average}, %{}, last: {1, :hour})
      # avg.points => [%{timestamp: ..., value: 12.4}, ...]
  """
  @spec series(Mobius.metric_name(), Exports.export_metric_type(), map(), [opt()]) :: series()
  def series(metric_name, type, tags \\ %{}, opts \\ [])

  def series(metric_name, :summary, tags, opts) do
    instance = opts[:mobius_instance] || :mobius
    {from, to} = resolve_window(opts)

    points =
      instance
      |> Data.summary_deltas(metric_name, tags, from, to)
      |> Enum.map(fn {ts, delta} -> %{timestamp: ts, value: Summary.calculate(delta)} end)

    %{
      metric: metric_name,
      type: :summary,
      tags: tags,
      window: %{from: from, to: to},
      points: points
    }
  end

  def series(metric_name, {:summary, field} = type, tags, opts)
      when field in [:average, :std_dev, :reports] do
    instance = opts[:mobius_instance] || :mobius
    {from, to} = resolve_window(opts)

    points =
      instance
      |> Data.summary_deltas(metric_name, tags, from, to)
      |> Enum.map(fn {ts, delta} ->
        %{timestamp: ts, value: Map.fetch!(Summary.calculate(delta), field)}
      end)

    %{
      metric: metric_name,
      type: type,
      tags: tags,
      window: %{from: from, to: to},
      points: points
    }
  end

  def series(metric_name, type, tags, opts) do
    {from, to} = resolve_window(opts)

    points =
      metric_name
      |> Exports.metrics(type, tags, Keyword.merge(opts, from: from, to: to))
      |> Enum.map(fn %{timestamp: ts, value: value} -> %{timestamp: ts, value: value} end)

    %{
      metric: metric_name,
      type: type,
      tags: tags,
      window: %{from: from, to: to},
      points: points
    }
  end

  @doc """
  The most recent stored value for each of several metrics.

  Each entry is `{name, type}` or `{name, type, tags}`. Metrics with no data in
  the window are omitted, so the result is ready to render directly. Order
  follows the input.

      Mobius.Charts.latest(
        [
          {"vm.memory.total", :last_value},
          {"vm.memory.processes", :last_value}
        ],
        last: {5, :minute}
      )
      # => [%{metric: "vm.memory.total", value: 51_200_000, timestamp: ...}, ...]
  """
  @spec latest([metric_ref()], [opt()]) :: [latest_value()]
  def latest(metrics, opts \\ []) do
    metrics
    |> Enum.flat_map(fn ref ->
      {name, type, tags} = normalize_ref(ref)

      case Exports.metrics(name, type, tags, opts) do
        [] ->
          []

        points ->
          %{timestamp: ts, value: value} = List.last(points)
          [%{metric: name, type: type, tags: tags, value: value, timestamp: ts}]
      end
    end)
  end

  # ----------------------------------------------------------------- helpers

  # One quantile's points across every window, dropping windows with no data.
  defp quantile_points(windows, q) do
    for {ts, sketch} <- windows,
        value = DDSketch.quantile(sketch, q),
        value != nil do
      %{timestamp: ts, value: value}
    end
  end

  # Project a sketch to bars sorted ascending by representative value. The
  # representative value of a bin is the DDSketch within-bin estimator
  # `2·γ^idx / (γ + 1)`, the same value `quantile/2` reports for that bin.
  defp bars(sketch) do
    gamma = sketch.gamma

    sketch
    |> DDSketch.bins()
    |> Enum.map(fn
      {{:hist, :zero}, count} -> {0.0, count}
      {{:hist, :pos, idx}, count} -> {bin_value(idx, gamma), count}
      {{:hist, :neg, idx}, count} -> {-bin_value(idx, gamma), count}
    end)
    |> Enum.sort()
    |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
  end

  defp bin_value(idx, gamma) do
    2.0 * :math.pow(gamma, idx) / (gamma + 1.0)
  end

  # Reconstruct one window sketch per stored snapshot interval. Each consecutive
  # pair of snapshots that carries this metric is a window; its distribution is
  # the bin-by-bin delta of the two cumulative sketch snapshots. Only windows
  # whose end falls inside [from, to] are emitted. An interval across which the
  # cumulative counters reset (e.g. after a reboot) is skipped, mirroring
  # summary_windows/5. Returns `{end_ts, sketch}` ascending.
  defp window_sketches(instance, key, sketch_opts, from, to) do
    instance
    |> Scraper.all_histograms()
    |> Enum.flat_map(fn {ts, histograms} ->
      case Map.fetch(histograms, key) do
        {:ok, snapshot} -> [{ts, snapshot}]
        :error -> []
      end
    end)
    |> Enum.filter(fn {ts, _} -> to - ts <= @max_history_seconds and ts <= to end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{_t0, earlier}, {t1, later}] when t1 >= from ->
        case DDSketch.delta(
               DDSketch.from_snapshot(sketch_opts, later),
               DDSketch.from_snapshot(sketch_opts, earlier)
             ) do
          {:ok, sketch} -> [{t1, sketch}]
          {:error, :reset} -> []
        end

      _ ->
        []
    end)
  end

  defp sketch_opts(%DDSketch{} = sketch) do
    [
      relative_accuracy: sketch.relative_accuracy,
      min_indexable_value: sketch.min_indexable_value,
      max_indexable_value: sketch.max_indexable_value,
      on_overflow: sketch.on_overflow
    ]
  end

  defp normalize_ref({name, type}), do: {name, type, %{}}
  defp normalize_ref({name, type, tags}), do: {name, type, tags}

  defp resolve_window(opts) do
    now = System.system_time(:second)

    cond do
      opts[:from] != nil -> {opts[:from], opts[:to] || now}
      opts[:last] != nil -> {now - last_seconds(opts[:last]), now}
      true -> {now - @default_window_seconds, now}
    end
  end

  defp last_seconds({n, :second}), do: n
  defp last_seconds({n, :minute}), do: n * 60
  defp last_seconds({n, :hour}), do: n * 3600
  defp last_seconds({n, :day}), do: n * 86_400
  defp last_seconds(n) when is_integer(n), do: n
end
