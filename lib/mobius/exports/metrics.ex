defmodule Mobius.Exports.Metrics do
  @moduledoc false

  # Module for exporting metrics

  alias Mobius.{Exports, Scraper}

  @doc """
  Export metrics
  """
  @spec export(binary(), Mobius.metric_type(), map(), [Exports.export_opt()]) :: [Mobius.metric()]
  def export(metric_name, type, tags, opts \\ []) do
    mobius_instance = opts[:mobius_instance] || :mobius

    start_t = System.monotonic_time()
    prefix = [:mobius, :export, :metrics]

    scraper_opts = query_opts(opts)

    # Notify telemetry we are starting query
    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, %{
      mobius_instance: mobius_instance,
      metric_name: metric_name,
      tags: tags,
      type: type,
      opts: scraper_opts
    })

    rows =
      Scraper.all(mobius_instance, scraper_opts)
      |> Enum.flat_map(fn {timestamp, metrics} ->
        rows_from_metrics(metrics, metric_name, tags, timestamp, type)
      end)

    # Notify telemetry we finished query
    duration = System.monotonic_time() - start_t

    :telemetry.execute(prefix ++ [:stop], %{duration: duration}, %{
      mobius_instance: mobius_instance,
      metric_name: metric_name,
      tags: tags,
      opts: scraper_opts
    })

    rows
  end

  defp rows_from_metrics(metrics, metric_name, tags, timestamp, required_type) do
    metrics
    |> Enum.flat_map(fn
      {^metric_name, type, value, metric_tags} ->
        if match?(^tags, metric_tags) and matches_type?(type, required_type) do
          [
            %{
              type: type,
              value: value,
              tags: metric_tags,
              timestamp: timestamp,
              name: metric_name
            }
          ]
        else
          []
        end

      _metric ->
        []
    end)
  end

  defp matches_type?(_type, nil), do: true

  defp matches_type?(type, type), do: true
  defp matches_type?(_, _), do: false

  defp query_opts(opts) do
    if opts[:from] do
      Keyword.take(opts, [:from, :to])
    else
      last_ts(opts)
    end
  end

  defp last_ts(opts) do
    now = System.system_time(:second)

    ts =
      case opts[:last] do
        nil ->
          now - 180

        {offset, unit} ->
          now - offset * get_unit_offset(unit)

        offset ->
          now - offset
      end

    [from: ts]
  end

  defp get_unit_offset(:second), do: 1
  defp get_unit_offset(:minute), do: 60
  defp get_unit_offset(:hour), do: 3600
  defp get_unit_offset(:day), do: 86400
end
