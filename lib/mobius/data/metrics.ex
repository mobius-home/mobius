defmodule Mobius.Data.Metrics do
  @moduledoc false

  # Self-contained implementation behind `Mobius.Data.metrics/4`: pull the
  # stored records from the scraper for a window and filter them down to a
  # single metric, summarizing summary records on the way out.

  alias Mobius.{Data, Scraper, Summary}

  @doc """
  Fetch the raw, un-delta'd rows for a metric over a window.
  """
  @spec export(binary(), Mobius.metric_type(), map(), [Mobius.Data.opt()]) :: [Mobius.metric()]
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
      |> filter_metrics_for_metric(metric_name, type, tags)

    # Notify telemetry we finished query
    duration = System.monotonic_time() - start_t

    :telemetry.execute(prefix ++ [:stop], %{duration: duration}, %{
      mobius_instance: mobius_instance,
      metric_name: metric_name,
      tags: tags,
      type: type,
      opts: scraper_opts
    })

    rows
  end

  defp filter_metrics_for_metric(records, metric_name, :summary, tags) do
    records
    |> do_filter_metrics_for_metric(metric_name, :summary, tags)
    |> Enum.map(fn {ts, {name, type, value, tg}} ->
      record_to_map({name, type, Summary.calculate(value), tg}, ts)
    end)
  end

  defp filter_metrics_for_metric(records, metric_name, {:summary, summary_metric}, tags) do
    records
    |> do_filter_metrics_for_metric(metric_name, :summary, tags)
    |> Enum.map(fn {ts, {name, type, value, tg}} ->
      summarized = value |> Summary.calculate() |> Map.get(summary_metric)
      record_to_map({name, type, summarized, tg}, ts)
    end)
  end

  defp filter_metrics_for_metric(records, metric_name, type, tags) do
    records
    |> do_filter_metrics_for_metric(metric_name, type, tags)
    |> Enum.map(fn {ts, record} -> record_to_map(record, ts) end)
  end

  defp do_filter_metrics_for_metric(records, metric_name, type, tags) do
    Enum.filter(records, fn {_ts, {name, rec_type, _value, rec_tags}} ->
      metric_name == name && match?(^tags, rec_tags) && type == rec_type
    end)
  end

  defp record_to_map({name, type, value, tags}, ts) do
    %{timestamp: ts, name: name, type: type, value: value, tags: tags}
  end

  defp query_opts(opts) do
    {from, to} = Data.resolve_window(opts)
    [from: from, to: to]
  end
end
