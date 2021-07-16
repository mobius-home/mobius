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

    history_list
    |> apply_filters(opts)
    |> apply_limit(previous)
  end

  defp apply_limit(list, num_prev_records) do
    num_records = length(list)

    if num_records > num_prev_records do
      Enum.drop(list, num_records - num_prev_records)
    else
      list
    end
  end

  defp apply_filters(list, opts) do
    tags = Keyword.get(opts, :tags, [])
    metric = Keyword.get(opts, :metric)

    case Keyword.get(opts, :event_name) do
      nil ->
        list

      name ->
        Enum.filter(list, fn
          {_date_time, {^name, item_metric, _value, meta}} ->
            check_type(item_metric, metric) && check_tags(meta, tags)

          _ ->
            false
        end)
    end
  end

  defp check_tags(meta, tag_filters) do
    Enum.reduce_while(tag_filters, true, fn {tag_name, tag_value}, is_ok ->
      if Map.has_key?(meta, tag_name) do
        if meta[tag_name] == tag_value do
          {:cont, is_ok}
        else
          {:halt, false}
        end
      else
        {:cont, is_ok}
      end
    end)
  end

  defp check_type(_metric, nil), do: true
  defp check_type(metric, filter_metric), do: metric == filter_metric

  @doc """
  Reads from the table and inserts the data into the history with the time stamp
  """
  @spec snapshot(t(), DateTime.t()) :: t()
  def snapshot(history, date_time) do
    metrics = Table.get_entries(history.table)

    insert_metrics(history, date_time, metrics)
  end

  defp insert_metrics(history, _date_time, []), do: history

  defp insert_metrics(history, date_time, [metric | metrics]) do
    buff = CircularBuffer.insert(history.buffer, {date_time, metric})

    insert_metrics(%{history | buffer: buff}, date_time, metrics)
  end
end
