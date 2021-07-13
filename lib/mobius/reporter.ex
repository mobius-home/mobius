defmodule Mobius.Reporter do
  @moduledoc false

  use GenServer

  alias Telemetry.Metrics
  alias Telemetry.Metrics.{Counter, LastValue}

  alias Mobius.Metrics.Table

  require Logger

  @typedoc """
  Arguments to the reporter server

  * `:metrics` - a list of telemetry metrics to report
  * `:table` - name of the `Mobius.MetricsTable` table that the reporter will
    report to
  """
  @type arg() :: {:metrics, [Metrics.t()]} | {:table_name, atom()}

  @doc """
  Start The reporter server
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(args) do
    all_metrics = Keyword.get(args, :metrics, [])
    table = Keyword.get(args, :table_name)

    for {event, metrics} <- Enum.group_by(all_metrics, & &1.event_name) do
      id = {__MODULE__, event, self()}
      :telemetry.attach(id, event, &handle_event/4, metrics: metrics, table_name: table)
    end

    {:ok, nil}
  end

  @doc """
  Handle for telemetry events
  """
  def handle_event(_event, measurements, metadata, opts) do
    metrics = Keyword.fetch!(opts, :metrics)
    table = Keyword.fetch!(opts, :table_name)

    # for the next part see: https://hexdocs.pm/telemetry_metrics/writing_reporters.html#reacting-to-events
    # for more information
    for metric <- metrics do
      try do
        if value = keep?(metric, metadata) && extract_measurement(metric, measurements, metadata) do
          tags = extract_tags(metric, metadata)
          update_metrics(table, metric, value, tags)
        end
      rescue
        e ->
          Logger.error("Could not format metric #{inspect(metric)}")
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      end
    end
  end

  defp update_metrics(table, %Counter{} = metric, _value, tags) do
    Table.inc_counter(table, metric.name, tags)
  end

  defp update_metrics(table, %LastValue{} = metric, value, tags) do
    Table.put(table, metric.name, :last_value, value, tags)
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
