defmodule Mobius.RRD do
  @moduledoc false

  # A round robin database for Mobius
  #
  # A round robin database (RRD) is a data store that a circular buffer to store
  # information. As time moves forward the older data points get overwritten by
  # newer data points.
  #
  # However, the older data points can be held on in an archive which operates
  # in a similar fashion. That is older data points will be over overwritten by
  # newer data points.
  #
  # The Mobius RRD has 3 archives which are minute, hour, day. These stores one
  # data point per time period the archive is named. For example, every minute
  # Mobius RRD will put a data point in the minute archive. These are called the
  # resolution.
  #
  # Each resolution can be configured to allow for as many signle data points as
  # you see fit. For example, if you want to store three days of data at an hour
  # resolutin you can configure the RRD like so:
  #
  # RRD.new(hour_count: 72)
  #
  # This will configure the hour resolution to store 72 hours worth of data points
  # in the hour archive.
  #
  # For more information about round robin databases, RRD tool is a great resource
  # to study.

  @serialization_version 1

  require Logger

  @type t() :: %{
          day: CircularBuffer.t(),
          hour: CircularBuffer.t(),
          minute: CircularBuffer.t(),
          second: CircularBuffer.t(),
          day_next: integer(),
          hour_next: integer(),
          minute_next: integer(),
          second_next: integer()
        }

  @spec new([Mobius.arg()]) :: t()
  def new(args) do
    %{
      day: CircularBuffer.new(args[:day_count]),
      hour: CircularBuffer.new(args[:hour_count]),
      minute: CircularBuffer.new(args[:minute_count]),
      second: CircularBuffer.new(args[:second_count]),
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
  @spec load(t(), binary()) :: {:ok, t()} | {:error, reason :: atom()}
  def load(rrd, <<@serialization_version, data::binary>>) do
    decoded =
      data
      |> :erlang.binary_to_term()
      |> Enum.reduce(rrd, fn {ts, item}, tlb -> insert(tlb, ts, item) end)

    {:ok, decoded}
  catch
    _, _ -> {:error, :corrupt}
  end

  def load(_rrd, _) do
    {:error, :unsupported_version}
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
