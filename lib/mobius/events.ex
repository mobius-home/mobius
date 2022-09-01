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
      process_event(config.table, event, measurements, metadata, config.event_opts)
    rescue
      e ->
        Logger.error("Could not process event #{inspect(event)}")
        Logger.error(Exception.format(:error, e, __STACKTRACE__))
    end

    :ok
  end

  def process_event(instance, event, measurements, metadata, opts) do
    measurements = process_measurements(measurements, opts)
    ts = System.system_time(:second)
    tags = get_event_tags(metadata, opts)

    event = Mobius.Event.new(event, ts, measurements, tags)

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
