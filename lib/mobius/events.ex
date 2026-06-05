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
  """
  @type event_handler_config() :: %{
          table: Mobius.instance(),
          metrics: [Metrics.t()]
        }

  @typedoc """
  The configuration that is passed to every handle metric call

  * `:table` - the metrics table name used to store metrics
  * `:metrics` - the list of metrics that Mobius is to listen for
  """
  @type metric_handler_config() :: %{
          table: Mobius.instance(),
          metrics: [Metrics.t()]
        }

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
    case histogram_opts(metric) do
      nil ->
        :ok

      opts ->
        sketch = Mobius.DDSketch.new(opts)

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
          nil -> nil
          false -> nil
          true -> []
          opts when is_list(opts) -> opts
        end

      _ ->
        nil
    end
  end

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
      case histogram_opts(metric) do
        nil ->
          acc

        opts ->
          key = {Enum.join(metric.name, "."), Enum.sort(metric.tags)}
          Map.put(acc, key, sketch_config(Mobius.DDSketch.new(opts)))
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
    Map.take(tag_values, metric.tags)
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

    event = Mobius.Event.new(session, event, measurements, tags)

    Mobius.EventsServer.insert(instance, event)
    :ok
  end

  defp process_measurements(measurements, opts) do
    case opts[:measurements_values] do
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
