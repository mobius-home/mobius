defmodule Mobius.Metrics.Table do
  @moduledoc false

  # Table for tracking current state of metrics

  # Internel table object structure
  # {{metric_name, metric_type, metadata}, value}

  # Exteneral object structure
  # {name, type, value, meta}

  @type arg() :: {:table_name, atom()}

  @type type() :: :counter | :last_value

  @type entry() :: {event_name :: term(), type(), value :: number(), meta :: map()}

  @doc """
  Initialize the meterics table
  """
  @spec init([arg()]) :: :ok
  def init(args) do
    table_name =
      Keyword.get(args, :table_name) ||
        raise ArgumentError, "Please provide a table name for the Mobius metrics table"

    :ets.new(table_name, [:named_table, :public, :set])

    :ok
  end

  defp make_key(name, type, meta), do: {name, type, meta}

  @doc """
  Put the metric information in to the metric table
  """
  @spec put(atom(), term(), type(), number(), map()) :: :ok
  def put(table_name, event_name, type, value, meta \\ %{})

  def put(table_name, event_name, :counter, _value, meta) do
    key = make_key(event_name, :counter, meta)

    # the counter value is located in the second positon of the tuple record
    count_position = 2

    # deafult value for the counter is 0
    default_spec = {count_position, 0}

    :ets.update_counter(table_name, key, {count_position, 1}, default_spec)

    :ok
  end

  def put(table_name, event_name, :last_value, value, meta) do
    key = make_key(event_name, :last_value, meta)

    :ets.insert(table_name, {key, value})

    :ok
  end

  @doc """
  Increament a counter metric
  """
  @spec inc_counter(atom(), term(), map()) :: :ok
  def inc_counter(table_name, event_name, meta \\ %{}) do
    put(table_name, event_name, :counter, 1, meta)
  end

  @doc """
  Get all entries in the table
  """
  @spec get_entries(atom()) :: [entry()]
  def get_entries(table_name) do
    ms = [
      {
        {{:"$1", :"$2", :"$3"}, :"$4"},
        [],
        [{{:"$1", :"$2", :"$4", :"$3"}}]
      }
    ]

    :ets.select(table_name, ms)
  end

  @doc """
  Get metrics by event name
  """
  @spec get_entries_by_event_name(atom(), term()) :: [entry()]
  def get_entries_by_event_name(table_name, event_name) do
    ms = [
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:==, :"$1", event_name}],
       [{{:"$1", :"$2", :"$4", :"$3"}}]}
    ]

    :ets.select(table_name, ms)
  end
end
