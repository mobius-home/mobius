defmodule Mobius.Events do
  @moduledoc false

  alias Mobius.MetricsTable

  alias Telemetry.Metrics
  alias Telemetry.Metrics.{Counter, LastValue, Sum, Summary}

  require Logger

  @typedoc """
  The configuration that is passed to every handle events call

  * `:table` - the metrics table name used to store metrics
  * `:event_opts` - the list of options to configure the event
  * `:session` - the session the event is recorded under
  """
  @type event_handler_config() :: %{
          table: Mobius.instance(),
          event_opts: keyword(),
          session: Mobius.session()
        }

  @typedoc """
  The configuration that is passed to every handle metric call

  * `:table` - the metrics table name used to store metrics
  * `:metrics` - the list of metrics that Mobius is to listen for
  * `:histogram_sketches` - the resolved empty sketch per
    histogram-enabled metric, built once at attach time by
    `metric_handler_config/2`
  """
  @type metric_handler_config() :: %{
          table: Mobius.instance(),
          metrics: [Metrics.t()],
          histogram_sketches: %{Metrics.t() => Mobius.DDSketch.t()}
        }

  @doc """
  Build the configuration passed to each `handle_metrics/4` call.

  Each histogram-enabled metric's sketch is resolved here, once, at
  attach time — the per-event hot path then only does a map lookup and a
  bin-index computation instead of re-validating options and rebuilding
  the sketch for every event. A metric whose histogram options don't
  validate simply gets no sketch entry, so bad configuration disables
  the histogram rather than raising per event.
  """
  @spec metric_handler_config(Mobius.instance(), [Metrics.t()]) :: metric_handler_config()
  def metric_handler_config(table, metrics) do
    sketches =
      Enum.reduce(metrics, %{}, fn metric, acc ->
        case resolve_sketch(metric) do
          nil -> acc
          sketch -> Map.put(acc, metric, sketch)
        end
      end)

    %{table: table, metrics: metrics, histogram_sketches: sketches}
  end

  # Resolve a metric's histogram options into an empty sketch, or nil when
  # histograms are not enabled or the options are invalid. Invalid options
  # are reported once at boot by sanitize_metrics/1, so this stays quiet.
  defp resolve_sketch(metric) do
    with opts when is_list(opts) <- histogram_opts(metric),
         {:ok, validated} <- Mobius.DDSketch.validate_opts(opts) do
      Mobius.DDSketch.new(validated)
    else
      _ -> nil
    end
  end

  @doc """
  Disable invalid histogram configurations in a metrics list.

  Mobius is observability, not the app's purpose — a typo in histogram
  options must not take the host application's supervision tree down.
  Each histogram-enabled summary metric is validated here, once, at
  boot: valid options are normalized (integers cast to floats) so every
  downstream consumer compares the same canonical configuration, and a
  metric whose options don't validate keeps working as a plain summary
  with its histogram disabled and one warning logged.
  """
  @spec sanitize_metrics([Metrics.t()]) :: [Metrics.t()]
  def sanitize_metrics(metrics) do
    Enum.map(metrics, &sanitize_metric/1)
  end

  defp sanitize_metric(%Summary{reporter_options: ro} = metric) when is_list(ro) do
    case Keyword.fetch(ro, :histogram) do
      :error ->
        metric

      {:ok, value} ->
        case sanitize_histogram_value(value) do
          {:ok, normalized} ->
            %{metric | reporter_options: Keyword.put(ro, :histogram, normalized)}

          {:error, message} ->
            Logger.warning(
              "[Mobius] Disabling histogram for metric #{Enum.join(metric.name, ".")}: #{message}"
            )

            %{metric | reporter_options: Keyword.put(ro, :histogram, false)}
        end
    end
  end

  defp sanitize_metric(metric), do: metric

  defp sanitize_histogram_value(value) when value in [nil, false, true], do: {:ok, value}

  defp sanitize_histogram_value(opts) when is_list(opts) do
    Mobius.DDSketch.validate_opts(opts)
  end

  defp sanitize_histogram_value(other) do
    {:error, "histogram must be a boolean or a DDSketch option list, got: #{inspect(other)}"}
  end

  @doc """
  Handle telemetry events
  """
  @spec handle_metrics(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          metric_handler_config()
        ) :: :ok
  def handle_metrics(_event, measurements, metadata, config) do
    for metric <- config.metrics do
      try do
        measurement = extract_measurement(metric, measurements, metadata)

        if !is_nil(measurement) and keep?(metric, metadata) do
          tags = extract_tags(metric, metadata)

          handle_metric(metric, measurement, tags, config)
        end
      rescue
        e ->
          Logger.error("Could not format metric #{inspect(metric)}")
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      end
    end

    :ok
  end

  # Counter only ever increments by one, regardless of metric value
  defp handle_metric(%Counter{} = metric, _value, labels, config) do
    MetricsTable.inc_counter(config.table, metric.name, labels)
  end

  defp handle_metric(%LastValue{} = metric, value, labels, config) do
    MetricsTable.put(config.table, metric.name, :last_value, value, labels)
  end

  defp handle_metric(%Sum{} = metric, value, labels, config) do
    MetricsTable.update_sum(config.table, metric.name, value, labels)
  end

  defp handle_metric(%Summary{} = metric, value, labels, config) do
    MetricsTable.put(config.table, metric.name, :summary, value, labels)
    maybe_record_histogram(metric, value, labels, config)
  end

  defp maybe_record_histogram(%Summary{} = metric, value, labels, config) do
    case Map.get(config.histogram_sketches, metric) do
      nil ->
        :ok

      sketch ->
        case Mobius.DDSketch.bin_key_for_value(sketch, value) do
          :drop -> :ok
          bin_key -> MetricsTable.inc_histogram_bin(config.table, metric.name, bin_key, labels)
        end
    end
  end

  @doc """
  Extract histogram opts from a metric's `reporter_options`.

  Returns the option list to pass to `Mobius.DDSketch.new/1`, or `nil` if
  histograms are not enabled for this metric. Only `Telemetry.Metrics.Summary`
  supports the histogram option.
  """
  @spec histogram_opts(Telemetry.Metrics.t()) :: keyword() | nil
  def histogram_opts(metric) do
    case metric do
      %Summary{reporter_options: ro} when is_list(ro) ->
        case Keyword.get(ro, :histogram) do
          true -> []
          opts when is_list(opts) -> opts
          # nil, false, or any invalid value: histograms are not enabled.
          # Invalid values are warned about (and disabled) at boot by
          # sanitize_metrics/1.
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Canonical identity of a histogram-enabled metric definition: the
  dotted metric name and its sorted tag keys.

  Persistence compatibility checks key the resolved sketch
  configurations by this identity in three places — the current-config
  map built by `histogram_configs/1`, the RRD file check, and the
  metrics-table dump check. They must all derive the key the same way,
  or valid histogram data gets dropped at load on a false mismatch.
  """
  @spec config_key(Metrics.normalized_metric_name() | Mobius.metric_name(), [atom()]) ::
          {Mobius.metric_name(), [atom()]}
  def config_key(name, tag_keys) when is_list(name),
    do: config_key(Enum.join(name, "."), tag_keys)

  def config_key(name, tag_keys) when is_binary(name), do: {name, Enum.sort(tag_keys)}

  @doc """
  Resolved sketch configuration per histogram-enabled metric definition.

  Keyed by `{metric_name, sorted_tag_keys}`. Resolving through
  `Mobius.DDSketch.new/1` means `histogram: true` and an explicitly
  spelled-out default configuration compare equal. Used by the
  persistence paths (RRD file and metrics table dump) to detect — and
  drop — histogram data recorded under a different configuration.
  """
  @spec histogram_configs([Telemetry.Metrics.t()]) ::
          %{{Mobius.metric_name(), [atom()]} => map()}
  def histogram_configs(metrics) do
    Enum.reduce(metrics, %{}, fn metric, acc ->
      case resolve_sketch(metric) do
        nil ->
          # Not histogram-enabled, or invalid options: either way there is
          # no current configuration, so persisted data for the metric is
          # dropped at load as no-longer-enabled.
          acc

        sketch ->
          Map.put(acc, config_key(metric.name, metric.tags), sketch_config(sketch))
      end
    end)
  end

  defp sketch_config(%Mobius.DDSketch{} = sketch) do
    Map.take(sketch, [
      :relative_accuracy,
      :min_indexable_value,
      :max_indexable_value,
      :on_overflow
    ])
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp extract_measurement(%Counter{}, _measurements, _metadata) do
    1
  end

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)

    # Record every declared tag — as nil when the event metadata lacks it —
    # so a series' recorded tag keys (and the histogram config key derived
    # from them) depend only on the metric definition, never on which keys
    # a particular event happened to carry.
    Map.new(metric.tags, &{&1, Map.get(tag_values, &1)})
  end

  @doc """
  Handle telemetry events
  """
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          event_handler_config()
        ) :: :ok
  def handle_event(event, measurements, metadata, config) do
    try do
      process_event(
        config.table,
        config.session,
        event,
        measurements,
        metadata,
        config.event_opts
      )
    rescue
      e ->
        Logger.error("Could not process event #{inspect(event)}")
        Logger.error(Exception.format(:error, e, __STACKTRACE__))
    end

    :ok
  end

  def process_event(instance, session, event, measurements, metadata, opts) do
    measurements = process_measurements(measurements, opts)
    tags = get_event_tags(metadata, opts)

    event = Mobius.Event.new(session, event, measurements, tags, Keyword.take(opts, [:group]))

    Mobius.EventsServer.insert(instance, event)
    :ok
  end

  defp process_measurements(measurements, opts) do
    # :measurements_values is a historical misspelling of the documented
    # :measurement_values option, kept for backward compatibility. The
    # documented key wins when both are given.
    case opts[:measurement_values] || opts[:measurements_values] do
      nil ->
        measurements

      values_translator ->
        Enum.reduce(measurements, %{}, fn {k, _v} = measurement, new_measurements ->
          new_value = values_translator.(measurement)

          Map.put(new_measurements, k, new_value)
        end)
    end
  end

  defp get_event_tags(metadata, opts) do
    allowed_tags = opts[:tags] || []

    Enum.reduce(allowed_tags, %{}, fn tag, tags ->
      case Map.get(metadata, tag) do
        nil ->
          tags

        value ->
          Map.put(tags, tag, value)
      end
    end)
  end
end
