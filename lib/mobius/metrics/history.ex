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
  @spec view(t(), [Mobius.History.view_opt()]) :: [Mobius.History.record()]
  def view(history, opts \\ []) do
    previous = Keyword.get(opts, :previous, 25)
    history_list = CircularBuffer.to_list(history.buffer)
    number_records = Enum.count(history_list)

    if number_records > previous do
      Enum.drop(history_list, number_records - previous)
    else
      history_list
    end
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
end
