defmodule Mobius.Exports.Histogram do
  @moduledoc false

  # Reconstruct DDSketch histograms for a metric over a time window from the
  # RRD snapshots, and run quantile / count queries on them.
  #
  # The reconstruction trick is exactly what makes the cumulative-counter
  # scheme cheap to query: take the earliest cumulative bin counts at the
  # start of the window and the latest cumulative bin counts at the end of
  # the window; the bin-by-bin delta is the window's true distribution.

  alias Mobius.{DDSketch, Events, Registry, Scraper}

  @type opt() ::
          {:mobius_instance, Mobius.instance()}
          | {:from, integer()}
          | {:to, integer()}
          | {:last, integer() | {integer(), Mobius.time_unit()}}

  @doc """
  Reconstruct the sketch for a metric over a window.

  Returns `{:ok, DDSketch.t()}` on success or `{:error, reason}` if the
  metric is not configured with histograms enabled. The returned sketch
  reflects the bin counts attributable to the window only — the
  cumulative-counter offset before the window is already subtracted out.

  An empty sketch is returned when no histogram observations fell into the
  window (or no snapshots covered it).
  """
  @spec histogram(Mobius.metric_name(), map(), [opt()]) ::
          {:ok, DDSketch.t()} | {:error, term()}
  def histogram(metric_name, tags, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius

    case find_histogram_metric(instance, metric_name, tags) do
      {:ok, metric} ->
        sketch_opts = Events.histogram_opts(metric)
        {from, to} = resolve_window(opts)

        # We need the latest snapshot *before* the window in order to
        # establish the cumulative-counter baseline, so we cannot push
        # from/to into the Scraper query — we pull everything and pick
        # boundary snapshots ourselves.
        snapshots = Scraper.all_histograms(instance)
        window_sketch = build_window_sketch(snapshots, metric_name, tags, sketch_opts, from, to)
        {:ok, window_sketch}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Quantile estimate for a metric over a window. See `DDSketch.quantile/2`.
  """
  @spec quantile(Mobius.metric_name(), float(), map(), [opt()]) ::
          {:ok, float() | nil} | {:error, term()}
  def quantile(metric_name, q, tags, opts \\ []) do
    with {:ok, sketch} <- histogram(metric_name, tags, opts) do
      {:ok, DDSketch.quantile(sketch, q)}
    end
  end

  @doc """
  Batch quantile estimates. See `DDSketch.quantiles/2`.
  """
  @spec quantiles(Mobius.metric_name(), [float()], map(), [opt()]) ::
          {:ok, %{float() => float() | nil}} | {:error, term()}
  def quantiles(metric_name, qs, tags, opts \\ []) do
    with {:ok, sketch} <- histogram(metric_name, tags, opts) do
      {:ok, DDSketch.quantiles(sketch, qs)}
    end
  end

  @doc """
  Count of observations below a threshold over the window. See
  `DDSketch.count_below/2`.
  """
  @spec count_below(Mobius.metric_name(), number(), map(), [opt()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_below(metric_name, threshold, tags, opts \\ []) do
    with {:ok, sketch} <- histogram(metric_name, tags, opts) do
      {:ok, DDSketch.count_below(sketch, threshold)}
    end
  end

  @doc """
  Count of observations above a threshold over the window. See
  `DDSketch.count_above/2`.
  """
  @spec count_above(Mobius.metric_name(), number(), map(), [opt()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_above(metric_name, threshold, tags, opts \\ []) do
    with {:ok, sketch} <- histogram(metric_name, tags, opts) do
      {:ok, DDSketch.count_above(sketch, threshold)}
    end
  end

  # ----------------------------------------------------------------- helpers

  defp find_histogram_metric(instance, metric_name, tags) do
    requested_tag_keys = tags |> Map.keys() |> Enum.sort()

    candidates =
      instance
      |> Registry.metrics()
      |> Enum.filter(fn m ->
        Enum.join(m.name, ".") == metric_name and
          Enum.sort(m.tags) == requested_tag_keys
      end)

    case Enum.find(candidates, &(Events.histogram_opts(&1) != nil)) do
      nil ->
        {:error,
         {:no_histogram_metric,
          "no histogram-enabled metric named #{inspect(metric_name)} with tag keys " <>
            inspect(requested_tag_keys)}}

      metric ->
        {:ok, metric}
    end
  end

  defp resolve_window(opts) do
    now = System.system_time(:second)

    cond do
      opts[:from] != nil ->
        {opts[:from], opts[:to] || now}

      opts[:last] != nil ->
        {now - last_seconds(opts[:last]), now}

      true ->
        # Default: the last 3 minutes, matching Exports.Metrics' default.
        {now - 180, now}
    end
  end

  defp last_seconds({n, :second}), do: n
  defp last_seconds({n, :minute}), do: n * 60
  defp last_seconds({n, :hour}), do: n * 3600
  defp last_seconds({n, :day}), do: n * 86400
  defp last_seconds(n) when is_integer(n), do: n

  defp build_window_sketch(snapshots, metric_name, tags, sketch_opts, from, to) do
    # Snapshots is a sorted list of {ts, %{{name, tags} => sketch_snapshot}}.
    # Find the sketch snapshot for this metric at each window endpoint.
    key = {metric_name, tags}

    earlier = snapshot_at_or_before(snapshots, key, from - 1)
    later = snapshot_at_or_before(snapshots, key, to)

    case later do
      nil ->
        DDSketch.new(sketch_opts)

      later_snapshot ->
        later_sketch = DDSketch.from_snapshot(sketch_opts, later_snapshot)

        earlier_sketch =
          case earlier do
            nil -> DDSketch.new(sketch_opts)
            snapshot -> DDSketch.from_snapshot(sketch_opts, snapshot)
          end

        DDSketch.delta(later_sketch, earlier_sketch)
    end
  end

  # Walk scrapes ascending; return the sketch snapshot from the latest scrape
  # whose timestamp is ≤ ts AND that contained this metric, or nil.
  defp snapshot_at_or_before(snapshots, key, ts) do
    snapshots
    |> Enum.take_while(fn {snap_ts, _} -> snap_ts <= ts end)
    |> Enum.reduce(nil, fn {_snap_ts, histograms}, acc ->
      case Map.fetch(histograms, key) do
        {:ok, snapshot} -> snapshot
        :error -> acc
      end
    end)
  end
end
