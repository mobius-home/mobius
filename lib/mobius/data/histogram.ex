defmodule Mobius.Data.Histogram do
  @moduledoc false

  # Reconstruct DDSketch histograms for a metric over a time window from the
  # RRD snapshots, and run quantile / count queries on them.
  #
  # The reconstruction trick is exactly what makes the cumulative-counter
  # scheme cheap to query: take the earliest cumulative bin counts at the
  # start of the window and the latest cumulative bin counts at the end of
  # the window; the bin-by-bin delta is the window's true distribution.

  alias Mobius.{Data, DDSketch, Events, Registry, Scraper}

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

  Snapshots are persisted, so a routine reboot loses nothing or
  next-to-nothing — the counters are restored and pick up where they
  left off. The cumulative counters only fall (a "reset") when the
  counter state is genuinely lost or rebuilt while older snapshots
  survive: corrupt or unreadable counter persistence, or a sketch-config
  change that invalidates the bins. In that case the pre-reset baseline
  is unusable and the result degrades to everything observed since the
  reset.

  If the pre-window baseline snapshot has rolled out of RRD retention,
  the window is truncated to the retained history (the oldest retained
  snapshot becomes the baseline) rather than silently over-counting.
  """
  @spec histogram(Mobius.metric_name(), map(), [opt()]) ::
          {:ok, DDSketch.t()} | {:error, term()}
  def histogram(metric_name, tags, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius

    case find_histogram_metric(instance, metric_name, tags) do
      {:ok, metric} ->
        sketch_opts = Events.histogram_opts(metric)
        {from, to} = Data.resolve_window(opts)

        # We need the latest snapshot *before* the window in order to
        # establish the cumulative-counter baseline, so we cannot push
        # from/to into the Scraper query — we pull everything and pick
        # boundary snapshots ourselves.
        snapshots = Scraper.all_histograms(instance)
        rolled_off? = Scraper.history_rolled_off?(instance)

        window_sketch =
          build_window_sketch(snapshots, rolled_off?, metric_name, tags, sketch_opts, from, to)

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

  @doc false
  # Public for tests: exercising the rolled-off baseline cases through the
  # full stack would need a day archive that has actually wrapped.
  def build_window_sketch(snapshots, rolled_off?, metric_name, tags, sketch_opts, from, to) do
    # Snapshots is a sorted list of {ts, %{{name, tags} => sketch_snapshot}}.
    # Find the sketch snapshot for this metric at each window endpoint.
    key = {metric_name, tags}

    earlier =
      case snapshot_at_or_before(snapshots, key, from - 1) do
        nil -> rolloff_baseline(snapshots, key, rolled_off?)
        snapshot -> snapshot
      end

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

        case DDSketch.delta(later_sketch, earlier_sketch) do
          {:ok, sketch} ->
            sketch

          {:error, :reset} ->
            # The cumulative counters fell between the two boundary
            # snapshots, so the counter state was lost or rebuilt — corrupt
            # counter persistence or a sketch-config change, not a routine
            # reboot (those restore the counters intact). The pre-window
            # baseline is unusable, so the later snapshot alone —
            # everything observed since the reset — is the best available
            # approximation of the window.
            later_sketch
        end
    end
  end

  # No snapshot exists at-or-before the window start. Either the metric
  # genuinely started inside the window (an empty cumulative baseline is
  # correct), or its earlier history rolled out of RRD retention (the true
  # baseline was lost). Counters are cumulative, so a metric that predates
  # retention appears in every retained scrape — including the very oldest.
  # When history has rolled off and the metric is in that oldest scrape, use
  # it as the baseline: the window is truncated to the retained history,
  # rather than misattributing the metric's entire cumulative history to
  # the window.
  defp rolloff_baseline(_snapshots, _key, false), do: nil

  defp rolloff_baseline([{_ts, histograms} | _], key, true), do: Map.get(histograms, key)

  defp rolloff_baseline([], _key, true), do: nil

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
