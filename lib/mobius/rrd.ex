defmodule Mobius.RRD do
  @moduledoc """
  A round robin database for Mobius

  This is RRD is used by Mobius to store historicial metric data.

  A round robin database (RRD) is a data store that a circular buffer to store
  information. As time moves forward the older data points get overwritten by
  newer data points. This type of data storage is useful for a consistent memory
  footprint for timeseries data.

  The `Mobius.RRD` implementation provides four resolutions. These are: seconds,
  minutes, hours, and days. Each resolution can be configured to allow for as
  many single data points as you see fit. For example, if you want to store three
  days of data at an hour resolutin you can configure the RRD like so:

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

  @serialization_version 1

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

  For resolution options you specifiy whitch resolution and the max number of
  metric data to keep for that resolution.

  For example, if the RRD were to track seconds up to five minutes it would need
  to track `300` seconds. Also, if the same RRD wanted to track day resolution
  for a year, it would need to be contain `365` days.

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

  @doc """
  Insert an item for the specified time
  """
  @spec insert(t(), integer(), any()) :: t()
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

  @doc """
  Load persisted data back into a TimeLayerBuffer

  The `rrd` that's passed in is expected to be a new one without any entries.
  """
  @spec load(t(), binary()) :: {:ok, t()} | {:error, Mobius.DataLoadError.t()}
  def load(rrd, <<@serialization_version, data::binary>>) do
    decoded =
      data
      |> :erlang.binary_to_term()
      |> Enum.reduce(rrd, fn {ts, item}, tlb -> insert(tlb, ts, item) end)

    {:ok, decoded}
  catch
    _, _ -> {:error, Mobius.DataLoadError.exception(reason: :corrupt, who: rrd)}
  end

  def load(rrd, _) do
    {:error, Mobius.DataLoadError.exception(reason: :unsupported_version, who: rrd)}
  end

  @doc """
  Serialize to an iolist
  """
  @spec save(t()) :: iolist()
  def save(rrd) do
    [@serialization_version, :erlang.term_to_iovec(all(rrd))]
  end

  @doc """
  Return all items in order
  """
  @spec all(t()) :: [{integer(), any()}]
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
  @spec query(t(), from :: integer(), to :: integer()) :: [{integer(), any()}]
  def query(rrd, from, to) do
    rrd
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
    |> Enum.take_while(fn {ts, _} -> ts <= to end)
  end

  @doc """
  Return all items with timestamps equal to or after the specified one
  """
  @spec query(t(), from :: integer()) :: [{integer(), any()}]
  def query(rrd, from) do
    rrd
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
  end
end
