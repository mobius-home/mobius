defmodule Mobius.History do
  @moduledoc false

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
  def insert(tlb, ts, item) do
    value = {ts, item}

    cond do
      ts >= tlb.day_next ->
        %{
          tlb
          | day: CircularBuffer.insert(tlb.day, value),
            day_next: next(ts, 86400),
            hour_next: next(ts, 3600),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= tlb.hour_next ->
        %{
          tlb
          | hour: CircularBuffer.insert(tlb.hour, value),
            hour_next: next(ts, 3600),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= tlb.minute_next ->
        %{
          tlb
          | minute: CircularBuffer.insert(tlb.minute, value),
            minute_next: next(ts, 60),
            second_next: ts + 1
        }

      ts >= tlb.second_next ->
        %{
          tlb
          | second: CircularBuffer.insert(tlb.second, value),
            second_next: ts + 1
        }

      true ->
        Logger.debug("Dropping scrape #{inspect(item)} at #{inspect(ts)}")
        tlb
    end
  end

  defp next(ts, res) do
    (div(ts, res) + 1) * res
  end

  @doc """
  Load persisted data back into a TimeLayerBuffer

  The `tlb` that's passed in is expected to be a new one without any entries.
  """
  @spec load(t(), binary()) :: {:ok, t()} | {:error, reason :: atom()}
  def load(tlb, <<@serialization_version, data::binary>>) do
    decoded =
      data
      |> :erlang.binary_to_term()
      |> Enum.reduce(tlb, fn {ts, item}, tlb -> insert(tlb, ts, item) end)

    {:ok, decoded}
  catch
    _, _ -> {:error, :corrupt}
  end

  def load(_tlb, _) do
    {:error, :unsupported_version}
  end

  @doc """
  Serialize to an iolist
  """
  @spec save(t()) :: iolist()
  def save(tlb) do
    [@serialization_version, :erlang.term_to_iovec(all(tlb))]
  end

  @doc """
  Return all items in order
  """
  @spec all(t()) :: [{integer(), any()}]
  def all(tlb) do
    result =
      CircularBuffer.to_list(tlb.day) ++
        CircularBuffer.to_list(tlb.hour) ++
        CircularBuffer.to_list(tlb.minute) ++ CircularBuffer.to_list(tlb.second)

    Enum.sort(result, fn {ts1, _}, {ts2, _} -> ts1 < ts2 end)
  end

  @doc """
  Return all items within the specified range
  """
  @spec query(t(), from :: integer(), to :: integer()) :: [{integer(), any()}]
  def query(tlb, from, to) do
    tlb
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
    |> Enum.take_while(fn {ts, _} -> ts <= to end)
  end

  @doc """
  Return all items with timestamps equal to or after the specified one
  """
  @spec query(t(), from :: integer()) :: [{integer(), any()}]
  def query(tlb, from) do
    tlb
    |> all()
    |> Enum.drop_while(fn {ts, _} -> ts < from end)
  end
end
