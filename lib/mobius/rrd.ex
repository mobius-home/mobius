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

  require Logger

  @opaque t() :: %{
            day: CircularBuffer.t(),
            hour: CircularBuffer.t(),
            minute: CircularBuffer.t(),
            second: CircularBuffer.t(),
            day_next: integer(),
            hour_next: integer(),
            minute_next: integer(),
            second_next: integer()
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
      second_next: 0
    }
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
    |> drop_incompatible_histograms(persisted_configs, opts[:histogram_configs])
    |> do_load(rrd)
  catch
    _, _ -> {:error, Mobius.DataLoadError.exception(reason: :corrupt, who: rrd)}
  end

  def load(rrd, _, _opts) do
    {:error, Mobius.DataLoadError.exception(reason: :unsupported_version, who: rrd)}
  end

  # No current configuration to check against: load everything as-is.
  defp drop_incompatible_histograms(snapshots, _persisted_configs, nil), do: snapshots

  defp drop_incompatible_histograms(snapshots, persisted_configs, current_configs) do
    {snapshots, dropped} =
      Enum.map_reduce(snapshots, MapSet.new(), fn
        {ts, {records, histograms}}, dropped ->
          {kept, dropped} =
            Enum.reduce(histograms, {%{}, dropped}, fn {key, payload}, {kept, dropped} ->
              {name, tags} = key
              config_key = {name, tags |> Map.keys() |> Enum.sort()}
              current = Map.get(current_configs, config_key)

              if current != nil and Map.get(persisted_configs, config_key) == current do
                {Map.put(kept, key, payload), dropped}
              else
                {kept, MapSet.put(dropped, config_key)}
              end
            end)

          {{ts, {records, kept}}, dropped}

        {ts, records}, dropped ->
          {{ts, records}, dropped}
      end)

    if MapSet.size(dropped) > 0 do
      Logger.warning(
        "Dropping persisted histogram data for #{inspect(MapSet.to_list(dropped))}: " <>
          "sketch configuration changed or histograms no longer enabled for the metric"
      )
    end

    snapshots
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

  * `:serialization_version` - the version of serialization format, defaults to
    most recent
  * `:histogram_configs` - the resolved sketch configuration per
    histogram-enabled metric, recorded in v3 files so `load/3` can detect
    histogram data produced under a different configuration
  """
  @type save_opt() ::
          {:serialization_version, 1 | 2 | 3}
          | {:histogram_configs, %{histogram_config_key() => map()}}

  @doc """
  Serialize to an iolist
  """
  @spec save(t(), [save_opt()]) :: iolist()
  def save(rrd, opts \\ []) do
    serialization_version = opts[:serialization_version] || @serialization_version

    payload =
      if serialization_version >= 3 do
        %{configs: opts[:histogram_configs] || %{}, data: all(rrd)}
      else
        all(rrd)
      end

    [serialization_version, :erlang.term_to_iovec(payload)]
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
