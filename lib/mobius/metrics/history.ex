defmodule Mobius.Metrics.History do
  @moduledoc false

  alias Mobius.Metrics.Table

  @typedoc """
  History for metrics

  * `:buffer` - The buffer the history is placed into
  * `:table` - the mertics table this history is related to
  * `:interval` - the interval in miliseconds the history is recorded
  """
  @type t() :: %{
          buffer: CircularBuffer.t(),
          table: atom(),
          interval: integer()
        }

  @doc """
  Initialize history
  """
  @spec init([Mobius.arg()]) :: t()
  def init(opts \\ []) do
    table_name =
      Keyword.get(opts, :table_name) || raise ArgumentError, "Please provided :table_name"

    buffer_size = Keyword.get(opts, :history_size, 500)
    snapshot_interval = Keyword.get(opts, :snapshot_interval, 1_000)
    buffer = CircularBuffer.new(buffer_size)

    %{buffer: buffer, table: table_name, interval: snapshot_interval}
  end

  @doc """
  View the records
  """
  @spec view(t()) :: [Mobius.History.record()]
  def view(history) do
    CircularBuffer.to_list(history.buffer)
  end

  @doc """
  Reads from the table and inserts the data into the history with the time stamp
  """
  @spec snapshot(t(), DateTime.t()) :: t()
  def snapshot(history, date_time) do
    metrics = Table.get_entries(history.table)
    new_buffer = CircularBuffer.insert(history.buffer, {date_time, metrics})

    %{history | buffer: new_buffer}
  end

  @doc """
  Print chart to screen of history values
  """
  @spec chart(t()) :: :ok
  def chart(history) do
    history
    |> view()
    |> Enum.flat_map(fn {_timestamp, metric} -> metric end)
    |> Enum.group_by(fn {event_name, event_type, _data, meta} ->
      {event_name, event_type, meta}
    end)
    |> Enum.each(fn {{event_name, type, meta}, ms} ->
      series = Enum.map(ms, fn {_en, _et, value, _meta} -> value end)
      {:ok, chart} = Mobius.Asciichart.plot(series, height: 10)

      chart = [
        "\t\t",
        IO.ANSI.yellow(),
        "Event: ",
        make_event_name(event_name, type),
        IO.ANSI.reset(),
        ", ",
        IO.ANSI.magenta(),
        "Metric: #{inspect(type)}, ",
        IO.ANSI.cyan(),
        "Tags: #{inspect(meta)}",
        IO.ANSI.reset(),
        "\n\n",
        chart
      ]

      IO.puts(chart)
    end)
  end

  defp make_event_name(event_name, :counter),
    do: event_name |> Enum.take(length(event_name) - 1) |> Enum.join(".")

  defp make_event_name(event_name, _type), do: Enum.join(event_name, ".")
end
