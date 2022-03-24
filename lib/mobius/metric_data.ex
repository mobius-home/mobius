defmodule Mobius.MetricData do
  @moduledoc false

  # helper functions for work with metric data

  # In Mobius metrics are normally stored in `{timestamp, [{name, type, value, tags}]}`
  # format. This format is called the "internal" format. However, for many user
  # facing functionality this format is not terribly useful. This module
  # provides functions to work with and reformat this type of data to the public
  # data structure `[Mobius.metric()]`.

  @type opt() :: {:filter_types, [Mobius.metric_type()]}

  @spec to_metric_rows([Mobius.record()], [opt()]) :: [Mobius.metric()]
  def to_metric_rows(internal_records, opts \\ []) do
    Enum.flat_map(internal_records, fn {timestamp, metrics} ->
      rows_from_metrics(timestamp, metrics, opts)
    end)
  end

  @spec to_metric_rows_for_metric(
          [Mobius.record()],
          Mobius.metric_name(),
          Mobius.metric_type(),
          map()
        ) :: [Mobius.metric()]
  def to_metric_rows_for_metric(internal_records, metric_name, metric_type, metric_tags) do
    Enum.flat_map(internal_records, fn {timestamp, metrics} ->
      rows_from_metrics(metrics, metric_name, metric_tags, timestamp, metric_type)
    end)
  end

  defp rows_from_metrics(timestamp, metrics, opts) do
    filter_types = opts[:filter_types] || []

    Enum.reduce(metrics, [], fn {metric_name, type, value, tags}, updated_metrics ->
      if type in filter_types do
        updated_metrics
      else
        updated_metrics ++ [metric_new(timestamp, metric_name, type, value, tags)]
      end
    end)
  end

  defp rows_from_metrics(metrics, metric_name, metrics_tags, timestamp, metric_type) do
    metrics
    |> Enum.flat_map(fn
      {^metric_name, type, value, tags} ->
        if match?(^metrics_tags, tags) and matches_type?(type, metric_type) do
          [metric_new(timestamp, metric_name, type, value, tags)]
        else
          []
        end

      _metric ->
        []
    end)
  end

  defp metric_new(timestamp, name, type, value, tags) do
    %{timestamp: timestamp, name: name, type: type, value: value, tags: tags}
  end

  defp matches_type?(_type, nil), do: true

  defp matches_type?(type, type), do: true
  defp matches_type?(_, _), do: false
end
