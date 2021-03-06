defmodule Mobius.Events do
  @moduledoc false

  alias Mobius.MetricsTable

  alias Telemetry.Metrics
  alias Telemetry.Metrics.{Counter, LastValue, Sum, Summary}

  require Logger

  @typedoc """
  The configuration that is passed to every handle call

  * `:table` - the metrics table name used to store metrics
  * `:metrics` - the list of metrics that Mobius is to listen for
  """
  @type handler_config() :: %{
          table: Mobius.instance(),
          metrics: [Metrics.t()]
        }

  @doc """
  Handle telemetry events
  """
  @spec handle(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          handler_config()
        ) :: :ok
  def handle(_event, measurements, metadata, config) do
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
end
