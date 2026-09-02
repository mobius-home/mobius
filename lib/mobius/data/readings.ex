defmodule Mobius.Data.Readings do
  @moduledoc false

  # The pure half of `Mobius.Data.readings/1`: turn the stored scrapes into
  # one flat map of numbers per step. Everything here is a function of its
  # arguments so the thinning and the per-type arithmetic can be tested on
  # synthetic scrapes without a running instance or a wall clock.

  alias Mobius.{DDSketch, Events, Summary}

  @default_step :minute
  @default_rate_unit :second
  @default_quantiles [0.5, 0.95, 0.99]

  @typedoc "A stored scrape: `{timestamp, {records, histograms}}`."
  @type snapshot() ::
          {integer(), {[Mobius.metric_record()], %{{Mobius.metric_name(), map()} => binary()}}}

  @typedoc "Sketch options per histogram-enabled series, keyed like `Events.config_key/2`."
  @type sketch_opts() :: %{{Mobius.metric_name(), [atom()]} => keyword()}

  @doc """
  The sketch configuration of every histogram-enabled metric, keyed by name
  and sorted tag keys, from the registered metric definitions.
  """
  @spec sketch_opts_by_series([Telemetry.Metrics.t()]) :: sketch_opts()
  def sketch_opts_by_series(metrics) do
    for metric <- metrics,
        opts = Events.histogram_opts(metric),
        opts != nil,
        into: %{},
        do: {Events.config_key(metric.name, metric.tags), opts}
  end

  @doc """
  Build the readings for the window `from..to` (inclusive, unix seconds)
  from the stored scrapes, oldest first.

  `snapshots` is the whole retained history, not just the window: the first
  reading in the window deltas against the reading before it. Readings with
  nothing to say (a first scrape holding only counters, say) are left out.
  """
  @spec build([snapshot()], sketch_opts(), integer(), integer(), keyword()) ::
          [Mobius.Data.reading()]
  def build(snapshots, sketch_opts, from, to, opts \\ []) do
    step = step_seconds(Keyword.get(opts, :step, @default_step))

    config = %{
      sketch_opts: sketch_opts,
      rate_divisor: rate_divisor(Keyword.get(opts, :rate_unit, @default_rate_unit)),
      quantiles: Keyword.get(opts, :quantiles, @default_quantiles),
      key: Keyword.get(opts, :key, &default_key/3)
    }

    snapshots
    |> Enum.sort_by(fn {ts, _} -> ts end)
    |> thin(step)
    |> Enum.map_reduce(nil, fn {ts, _} = snapshot, previous ->
      {{ts, reading_metrics(snapshot, previous, config)}, snapshot}
    end)
    |> elem(0)
    |> Enum.filter(fn {ts, metrics} -> ts >= from and ts <= to and map_size(metrics) > 0 end)
    |> Enum.map(fn {ts, metrics} -> %{timestamp: ts, metrics: metrics} end)
  end

  @doc """
  The default series name: the metric name, then the tag values sorted by tag
  key, then the field, all dot-joined.

      iex> Mobius.Data.Readings.default_key("vm.memory.total", %{}, nil)
      "vm.memory.total"
      iex> Mobius.Data.Readings.default_key("net.tx_bytes", %{ifname: "wlan0"}, :rate)
      "net.tx_bytes.wlan0.rate"
      iex> Mobius.Data.Readings.default_key("http.duration", %{}, {:quantile, 0.999})
      "http.duration.p99.9"
  """
  @spec default_key(Mobius.metric_name(), map(), Mobius.Data.reading_field()) :: String.t()
  def default_key(name, tags, field) do
    tag_part =
      tags
      |> Enum.sort_by(fn {tag_key, _value} -> tag_key end)
      |> Enum.map(fn {_tag_key, value} -> tag_string(value) end)

    Enum.join([name | tag_part] ++ field_part(field), ".")
  end

  defp field_part(nil), do: []
  defp field_part({:quantile, q}), do: ["p" <> quantile_label(q)]
  defp field_part(field) when is_atom(field), do: [Atom.to_string(field)]

  # 0.5 -> "50", 0.95 -> "95", 0.999 -> "99.9"; never "95.0".
  defp quantile_label(q) do
    percent = q * 100

    if percent == Float.round(percent) do
      Integer.to_string(trunc(percent))
    else
      percent |> Float.round(3) |> Float.to_string()
    end
  end

  defp tag_string(value) when is_binary(value), do: value
  defp tag_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp tag_string(value), do: inspect(value)

  # ------------------------------------------------------------- thinning

  # The earliest scrape in each bucket stands for the bucket; nothing is
  # merged. The scrapes are already the first of their second/minute/hour/day
  # where the RRD kept one, so at the matching step this selects exactly
  # those, and at a coarser step it sub-samples.
  defp thin(sorted_snapshots, step) do
    Enum.uniq_by(sorted_snapshots, fn {ts, _} -> div(ts, step) end)
  end

  defp step_seconds(:second), do: 1
  defp step_seconds(:minute), do: 60
  defp step_seconds(:hour), do: 3_600
  defp step_seconds(:day), do: 86_400
  defp step_seconds(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp rate_divisor(:second), do: 1
  defp rate_divisor(:minute), do: 60
  defp rate_divisor(:hour), do: 3_600

  # ------------------------------------------------------------ per scrape

  defp reading_metrics({ts, {records, histograms}}, previous, config) do
    previous_records = previous_records(previous)

    from_records =
      for {name, type, value, tags} <- records,
          {field, number} <-
            values(type, value, previous_records[{name, type, tags}], ts, previous, config),
          key = config.key.(name, tags, field),
          is_binary(key),
          do: {key, number}

    from_histograms =
      for {{name, tags} = series, payload} <- histograms,
          sketch_opts = Map.get(config.sketch_opts, Events.config_key(name, Map.keys(tags))),
          sketch_opts != nil,
          {q, number} <-
            quantile_values(sketch_opts, payload, previous_histogram(previous, series), config),
          key = config.key.(name, tags, {:quantile, q}),
          is_binary(key),
          do: {key, number}

    Map.new(from_records ++ from_histograms)
  end

  defp previous_records(nil), do: %{}

  defp previous_records({_ts, {records, _histograms}}) do
    Map.new(records, fn {name, type, value, tags} -> {{name, type, tags}, value} end)
  end

  defp previous_histogram(nil, _series), do: nil
  defp previous_histogram({_ts, {_records, histograms}}, series), do: Map.get(histograms, series)

  # A gauge is its value; anything that is not a number cannot be shipped.
  defp values(:last_value, value, _previous, _ts, _previous_snapshot, _config)
       when is_number(value),
       do: [{nil, value}]

  defp values(:last_value, _value, _previous, _ts, _previous_snapshot, _config), do: []

  # Cumulative types need a predecessor. A fall between two scrapes is a
  # reset (the state was lost or rebuilt), and the interval spanning it has
  # no honest number.
  defp values(type, value, previous, ts, {previous_ts, _}, config)
       when type in [:counter, :sum] and is_number(value) and is_number(previous) and
              value >= previous and ts > previous_ts do
    [{:rate, (value - previous) / (ts - previous_ts) * config.rate_divisor}]
  end

  defp values(type, _value, _previous, _ts, _previous_snapshot, _config)
       when type in [:counter, :sum],
       do: []

  defp values(
         :summary,
         %{reports: n} = value,
         %{reports: previous_n} = previous,
         _ts,
         _previous_snapshot,
         _config
       )
       when n > previous_n do
    delta = %{
      accumulated: value.accumulated - previous.accumulated,
      accumulated_sqrd: value.accumulated_sqrd - previous.accumulated_sqrd,
      reports: n - previous_n
    }

    summary_fields(delta)
  end

  defp values(:summary, _value, _previous, _ts, _previous_snapshot, _config), do: []

  # Anything else (histogram bin rows never reach here, but a future type
  # might) is not a number we know how to read.
  defp values(_type, _value, _previous, _ts, _previous_snapshot, _config), do: []

  defp summary_fields(delta) do
    stats = Summary.calculate(delta)
    [{:average, stats.average}, {:std_dev, stats.std_dev}, {:reports, stats.reports}]
  end

  # The window's distribution is the bin-by-bin delta of two cumulative
  # sketches, exactly as `Mobius.Data.Histogram` does at window edges. Without
  # a predecessor the observations since the metric began are not "this
  # step's", so nothing is reported; likewise across a reset.
  defp quantile_values(_sketch_opts, _payload, nil, _config), do: []

  defp quantile_values(sketch_opts, payload, previous_payload, config) do
    later = DDSketch.from_snapshot(sketch_opts, payload)
    earlier = DDSketch.from_snapshot(sketch_opts, previous_payload)

    # An empty delta (no observations this step) estimates every quantile
    # as nil, which the filter drops.
    case DDSketch.delta(later, earlier) do
      {:ok, sketch} ->
        for {q, estimate} <- DDSketch.quantiles(sketch, config.quantiles),
            is_number(estimate),
            do: {q, estimate}

      {:error, :reset} ->
        []
    end
  rescue
    # A payload that does not decode to a sketch (corrupt persistence that
    # slipped past load-time sanitising) is skipped, not fatal to the reading.
    ArgumentError -> []
  end
end
