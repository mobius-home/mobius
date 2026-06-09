defmodule Mobius.RRD do
  @moduledoc """
  A round robin database for Mobius

  This is the RRD used by Mobius to store historical metric data.

  A round robin database (RRD) is a data store that has a circular buffer to store
  information. As time moves forward the older data points get overwritten by
  newer data points. This type of data storage is useful for a consistent memory
  footprint for time series data.

  The `Mobius.RRD` implementation provides four time resolutions. These are: seconds,
  minutes, hours and days. Each resolution can be configured to allow for as
  many single data points as you see fit. For example, if you want to store three
  days of data at an hour resolution you can configure the RRD like so:

  ```elixir
  RRD.new(hours: 72)
  ```

  The above will configure the hour resolution to store 72 hours worth of data points
  in the hour archive.

  The default resolutions are:

  * 60 days (each day for about 2 months)
  * 48 hours (each hour for 2 days)
  * 120 minutes (each minute for 2 hours)
  * 120 seconds (each second for 2 minutes)

  For more information about round robin databases, RRD tool is a great resource
  to study.
  """

  @serialization_version 3
  @default_compression_level 9

  require Logger

  @opaque t() :: %{
            day: CircularBuffer.t(),
            hour: CircularBuffer.t(),
            minute: CircularBuffer.t(),
            second: CircularBuffer.t(),
            day_next: integer(),
            hour_next: integer(),
            minute_next: integer(),
            second_next: integer(),
            day_capacity: pos_integer(),
            hour_capacity: pos_integer(),
            minute_capacity: pos_integer(),
            second_capacity: pos_integer()
          }

  @typedoc """
  Resolution name
  """
  @type resolution() :: :seconds | :minutes | :hours | :days

  @typedoc """
  Options for the RRD

  For resolution options you specify which resolution and the max number of
  metric data to keep for that resolution.

  For example, if the RRD were to track seconds up to five minutes it would need
  to track `300` seconds. Also, if the same RRD wanted to track day resolution
  for a year, it would need to contain `365` days.

  ```elixir
  Mobius.RRD.new(seconds: 300, days: 365)
  ```
  """
  @type create_opt() :: {resolution(), non_neg_integer()}

  @doc """
  Create a new RRD

  The default resolution values are:

  * 60 days (each day for about 2 months)
  * 48 hours (each hour for 2 days)
  * 120 minutes (each minute for 2 hours)
  * 120 seconds (each second for 2 minutes)
  """
  @spec new([create_opt()]) :: t()
  def new(opts \\ []) do
    days = opts[:days] || 60
    hours = opts[:hours] || 48
    minutes = opts[:minutes] || 120
    seconds = opts[:seconds] || 120

    %{
      day: CircularBuffer.new(days),
      hour: CircularBuffer.new(hours),
      minute: CircularBuffer.new(minutes),
      second: CircularBuffer.new(seconds),
      day_next: 0,
      hour_next: 0,
      minute_next: 0,
      second_next: 0,
      day_capacity: days,
      hour_capacity: hours,
      minute_capacity: minutes,
      second_capacity: seconds
    }
  end

  @doc """
  Whether the RRD may have discarded its oldest scrapes.

  The day archive holds the oldest retained data, so history starts
  rolling off once it has filled to capacity. Window queries use this to
  distinguish "the metric started inside retention" (an absent
  pre-window snapshot means an empty cumulative baseline) from "the
  metric's earlier history rolled off" (an absent pre-window snapshot
  means the baseline was lost, and the window must be truncated to the
  retained data instead).
  """
  @spec rolled_off?(t()) :: boolean()
  def rolled_off?(rrd) do
    Enum.count(rrd.day) >= rrd.day_capacity
  end

  @typedoc """
  Snapshot payload stored at each RRD timestamp.

  A `{records, histograms}` tuple where `records` is the list of regular
  `t:Mobius.metric_record/0` tuples and `histograms` is the compact per-metric
  histogram payload map from `Mobius.Scraper` (one
  `:erlang.term_to_binary/1`-encoded sketch snapshot per metric series).

  Plain `[Mobius.metric_record()]` is also accepted for backwards compatibility
  with older callers; it is treated as records with no histogram data.
  """
  @type snapshot() ::
          {[Mobius.metric_record()], Mobius.Scraper.histograms()}
          | [Mobius.metric_record()]

  @doc """
  Insert an item for the specified time
  """
  @spec insert(t(), integer(), snapshot()) :: t()
  def insert(rrd, ts, item) do
    value = {ts, item}

    cond do
      ts >= rrd.day_next ->
        %{
          rrd
          | day: CircularBuffer.insert(rrd.day, value),
            day_next: next(ts, 86400),
            hour_next: next(ts, 3600),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= rrd.hour_next ->
        %{
          rrd
          | hour: CircularBuffer.insert(rrd.hour, value),
            hour_next: next(ts, 3600),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= rrd.minute_next ->
        %{
          rrd
          | minute: CircularBuffer.insert(rrd.minute, value),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= rrd.second_next ->
        %{
          rrd
          | second: CircularBuffer.insert(rrd.second, value),
            second_next: ts + 1
        }

      true ->
        Logger.debug("Dropping scrape #{inspect(item)} at #{inspect(ts)}")
        rrd
    end
  end

  defp next(ts, res) do
    (div(ts, res) + 1) * res
  end

  # How far below the second high-water mark an insert may land before it
  # is treated as a backwards wall-clock step instead of ordinary jitter.
  @regression_margin 60

  @doc """
  Insert an item for the specified time, recovering from backwards clock steps

  Behaves like `insert/3` unless `ts` is more than #{@regression_margin} seconds
  below the second high-water mark. The marks only move forward, so after the
  wall clock steps backwards that far `insert/3` would silently drop every
  scrape until the clock catches back up — and since the RRD is persisted, the
  condition survives reboots. A trusted clock that steps backwards also means
  everything recorded above `ts` was stamped by a clock now known to have been
  ahead, so those entries are pruned (and the high-water marks reset) before
  the item is inserted. Backwards jitter within the margin keeps the `insert/3`
  drop behavior.

  Callers are expected to only use this with timestamps from a synchronized
  clock: a pre-sync timestamp (e.g. 1970-era before NTP) would prune valid
  history.
  """
  @spec insert_with_regression_recovery(t(), integer(), snapshot()) :: t()
  def insert_with_regression_recovery(rrd, ts, item) do
    if ts < rrd.second_next - @regression_margin do
      rrd
      |> prune_future(ts)
      |> insert(ts, item)
    else
      insert(rrd, ts, item)
    end
  end

  # CircularBuffer has no removal, so each archive is rebuilt from the
  # entries at or before ts; the reset marks let the following insert land.
  defp prune_future(rrd, ts) do
    {day, dropped_day} = prune_buffer(rrd.day, rrd.day_capacity, ts)
    {hour, dropped_hour} = prune_buffer(rrd.hour, rrd.hour_capacity, ts)
    {minute, dropped_minute} = prune_buffer(rrd.minute, rrd.minute_capacity, ts)
    {second, dropped_second} = prune_buffer(rrd.second, rrd.second_capacity, ts)

    dropped = dropped_day + dropped_hour + dropped_minute + dropped_second

    Logger.warning(
      "Pruning #{dropped} metric snapshot(s) stamped after #{ts}" <>
        " - the clock stepped backwards, so they were recorded under a clock that was ahead"
    )

    %{
      rrd
      | day: day,
        hour: hour,
        minute: minute,
        second: second,
        day_next: 0,
        hour_next: 0,
        minute_next: 0,
        second_next: 0
    }
  end

  defp prune_buffer(buffer, capacity, ts) do
    entries = CircularBuffer.to_list(buffer)
    kept = Enum.filter(entries, fn {entry_ts, _item} -> entry_ts <= ts end)

    rebuilt =
      Enum.reduce(kept, CircularBuffer.new(capacity), fn entry, acc ->
        CircularBuffer.insert(acc, entry)
      end)

    {rebuilt, length(entries) - length(kept)}
  end

  @typedoc """
  Identity of a histogram-enabled metric definition: name plus sorted tag keys.
  """
  @type histogram_config_key() :: {Mobius.metric_name(), [atom()]}

  @typedoc """
  Options for loading a persisted RRD

  * `:histogram_configs` - the current resolved sketch configuration per
    histogram-enabled metric. When given, v3 files are checked series by
    series and persisted histogram data whose recorded configuration does
    not match the current one is dropped — bin indices are meaningless
    under a different configuration, so reinterpreting them would produce
    silently wrong quantiles. When omitted, no compatibility check is
    performed.
  """
  @type load_opt() :: {:histogram_configs, %{histogram_config_key() => map()}}

  @doc """
  Load persisted data back into a TimeLayerBuffer

  The `rrd` that's passed in is expected to be a new one without any entries.
  """
  @spec load(t(), binary(), [load_opt()]) :: {:ok, t()} | {:error, Mobius.DataLoadError.t()}
  def load(rrd, binary, opts \\ [])

  def load(rrd, <<1, data::binary>>, _opts) do
    data
    |> :erlang.binary_to_term()
    |> migrate_data(1)
    |> migrate_data(2)
    |> do_load(rrd)
  catch
    _, _ -> {:error, Mobius.DataLoadError.exception(reason: :corrupt, who: rrd)}
  end

  def load(rrd, <<2, data::binary>>, _opts) do
    data
    |> :erlang.binary_to_term()
    |> migrate_data(2)
    |> do_load(rrd)
  catch
    _, _ -> {:error, Mobius.DataLoadError.exception(reason: :corrupt, who: rrd)}
  end

  def load(rrd, <<@serialization_version, data::binary>>, opts) do
    %{configs: persisted_configs, data: snapshots} = :erlang.binary_to_term(data)

    snapshots
    |> sanitize_histograms(persisted_configs, opts[:histogram_configs])
    |> do_load(rrd)
  catch
    _, _ -> {:error, Mobius.DataLoadError.exception(reason: :corrupt, who: rrd)}
  end

  def load(rrd, _, _opts) do
    {:error, Mobius.DataLoadError.exception(reason: :unsupported_version, who: rrd)}
  end

  # Walk every persisted histogram entry and drop the ones that cannot be
  # trusted, keeping everything else in the snapshot:
  #
  #   * corrupt entries — payloads that survived the outer decode but do not
  #     decode to a valid sketch snapshot would otherwise raise at *query*
  #     time, deep inside `Mobius.DDSketch.from_snapshot/2`
  #   * incompatible entries — recorded under a sketch configuration that no
  #     longer matches the current one (bin indices are meaningless under a
  #     different configuration, so reinterpreting them would produce
  #     silently wrong quantiles); only checked when `current_configs` is
  #     given
  defp sanitize_histograms(snapshots, persisted_configs, current_configs) do
    {snapshots, {corrupt, incompatible}} =
      Enum.map_reduce(snapshots, {MapSet.new(), MapSet.new()}, fn
        {ts, {records, histograms}}, acc ->
          {kept, acc} = sanitize_entries(histograms, acc, persisted_configs, current_configs)
          {{ts, {records, kept}}, acc}

        {ts, records}, acc ->
          {{ts, records}, acc}
      end)

    if MapSet.size(corrupt) > 0 do
      Logger.warning(
        "Dropping corrupt persisted histogram data for #{inspect(MapSet.to_list(corrupt))}"
      )
    end

    if MapSet.size(incompatible) > 0 do
      Logger.warning(
        "Dropping persisted histogram data for #{inspect(MapSet.to_list(incompatible))}: " <>
          "sketch configuration changed or histograms no longer enabled for the metric"
      )
    end

    snapshots
  end

  defp sanitize_entries(histograms, acc, persisted_configs, current_configs) do
    Enum.reduce(histograms, {%{}, acc}, fn {key, payload}, {kept, {corrupt, incompatible}} ->
      case check_histogram_entry(key, payload, persisted_configs, current_configs) do
        :ok ->
          {Map.put(kept, key, payload), {corrupt, incompatible}}

        :corrupt ->
          {kept, {MapSet.put(corrupt, key), incompatible}}

        {:incompatible, config_key} ->
          {kept, {corrupt, MapSet.put(incompatible, config_key)}}
      end
    end)
  end

  defp check_histogram_entry({name, tags} = _key, payload, persisted_configs, current_configs)
       when is_binary(name) and is_map(tags) do
    cond do
      not valid_histogram_payload?(payload) ->
        :corrupt

      current_configs == nil ->
        # No current configuration to check against: keep as-is.
        :ok

      true ->
        config_key = Mobius.Events.config_key(name, Map.keys(tags))
        current = Map.get(current_configs, config_key)

        if current != nil and Map.get(persisted_configs, config_key) == current do
          :ok
        else
          {:incompatible, config_key}
        end
    end
  end

  defp check_histogram_entry(_key, _payload, _persisted_configs, _current_configs), do: :corrupt

  # A valid at-rest payload is the term_to_binary encoding of a
  # `t:Mobius.DDSketch.snapshot/0`: {positive_bins, negative_bins, zero_count}
  # with integer bin indices and non-negative integer counts. The decode is
  # `:safe` — a damaged payload must not allocate atoms.
  defp valid_histogram_payload?(payload) when is_binary(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {pos, neg, zero} when is_map(pos) and is_map(neg) and is_integer(zero) and zero >= 0 ->
        valid_bin_map?(pos) and valid_bin_map?(neg)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp valid_histogram_payload?(_payload), do: false

  defp valid_bin_map?(bins) do
    Enum.all?(bins, fn {idx, count} ->
      is_integer(idx) and is_integer(count) and count >= 0
    end)
  end

  defp do_load(data, rrd) when is_list(data) do
    loaded =
      Enum.reduce(data, rrd, fn {ts, metrics}, new_rrd ->
        insert(new_rrd, ts, metrics)
      end)

    {:ok, loaded}
  end

  # migrate data from version 1 to version 2: turn dotted-list names into binaries
  # and rewrite legacy tuple-shape records as 5-key maps so the v2 → v3 step can
  # handle them uniformly.
  defp migrate_data(data, 1) do
    Enum.map(data, fn {timestamp, metrics} ->
      metrics =
        Enum.map(metrics, fn {name, type, value, tags} ->
          name = Enum.join(name, ".")
          %{name: name, type: type, value: value, tags: tags, timestamp: timestamp}
        end)

      {timestamp, metrics}
    end)
  end

  # migrate data from version 2 to version 3: drop the redundant inner
  # `:timestamp` field, pack each record as a positional tuple, and wrap
  # the records list in a `{records, histograms}` snapshot tuple. v2
  # files never carried histogram data, so the histograms map is empty.
  defp migrate_data(data, 2) do
    Enum.map(data, fn {timestamp, metrics} ->
      records =
        Enum.map(metrics, fn
          %{name: name, type: type, value: value, tags: tags} ->
            {name, type, value, tags}

          {_name, _type, _value, _tags} = record ->
            record
        end)

      {timestamp, {records, %{}}}
    end)
  end

  @typedoc """
  Options for saving RRD into a binary

  * `:histogram_configs` - the resolved sketch configuration per
    histogram-enabled metric, recorded in v3 files so `load/3` can detect
    histogram data produced under a different configuration
  * `:compression_level` - the zlib level (`0..9`) used to compress the payload,
    defaults to `9`. `0` disables compression.
  """
  @type save_opt() ::
          {:histogram_configs, %{histogram_config_key() => map()}}
          | {:compression_level, 0..9}

  @doc """
  Serialize to an iolist

  Always writes the current serialization format; `load/3` handles older
  formats on the way back in.
  """
  @spec save(t(), [save_opt()]) :: iolist()
  def save(rrd, opts \\ []) do
    compression_level = opts[:compression_level] || @default_compression_level
    payload = %{configs: opts[:histogram_configs] || %{}, data: all(rrd)}

    [
      @serialization_version,
      :erlang.term_to_binary(payload, [{:compressed, compression_level}])
    ]
  end

  @doc """
  Return all items in order
  """
  @spec all(t()) :: [{Mobius.timestamp(), snapshot()}]
  def all(rrd) do
    result =
      CircularBuffer.to_list(rrd.day) ++
        CircularBuffer.to_list(rrd.hour) ++
        CircularBuffer.to_list(rrd.minute) ++ CircularBuffer.to_list(rrd.second)

    Enum.sort(result, fn {ts1, _}, {ts2, _} -> ts1 < ts2 end)
  end

  @doc """
  Return all items within the specified range
  """
  @spec query(t(), from :: integer(), to :: integer()) :: [{integer(), snapshot()}]
  def query(rrd, from, to) do
    rrd
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
    |> Enum.take_while(fn {ts, _} -> ts <= to end)
  end

  @doc """
  Return all items with timestamps equal to or after the specified one
  """
  @spec query(t(), from :: integer()) :: [{integer(), snapshot()}]
  def query(rrd, from) do
    rrd
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
  end
end
