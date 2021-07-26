defmodule Mobius.Events do
  @moduledoc false

  alias Mobius.MetricsTable

  alias Telemetry.Metrics
  alias Telemetry.Metrics.{Counter, LastValue}

  require Logger

  @typedoc """
  The configuration that is passed to every handle call

  * `:table` - the metrics table name used to store metrics
  * `:metrics` - the list of metrics that Mobius is to listen for
  """
  @type handler_config() :: %{
          table: Mobius.name(),
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
        if value = keep?(metric, metadata) && extract_measurement(metric, measurements, metadata) do
          tags = extract_tags(metric, metadata)
          handle_metric(metric, value, tags, config)
        end
      rescue
        e ->
          Logger.error("Could not format metric #{inspect(metric)}")
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      end
    end

    :ok
  end

  defp handle_metric(%Counter{} = metric, _value, labels, config) do
    MetricsTable.inc_counter(config.table, metric.name, labels)
  end

  defp handle_metric(%LastValue{} = metric, value, labels, config) do
    MetricsTable.put(config.table, metric.name, :last_value, value, labels)
  end

  defp keep?(%{keep: keep}, metadata) when keep != nil, do: keep.(metadata)
  defp keep?(_metric, _metadata), do: true

  defp extract_measurement(%Counter{}, _measurements, _metadata) do
    1
  end

  defp extract_measurement(metric, measurements, metadata) do
    get_measurement(metric, measurements, metadata)
  end

  defp get_measurement(metric, measurements, metadata) do
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
