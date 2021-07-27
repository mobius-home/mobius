defmodule Mobius.MetricsTable do
  @moduledoc false

  # Table for tracking current state of metrics

  # Internal table object structure
  # {{metric_name, metric_type, metadata}, value}

  # External object structure
  # {name, type, value, meta}

  @type name() :: atom()

  @typedoc """
  The structure of how metric information from the metrics table
  """
  @type metric_entry() :: {:telemetry.event_name(), Mobius.metric_type(), integer(), map()}

  @doc """
  Initialize the metrics table
  """
  @spec init(name()) :: name()
  def init(name) do
    :ets.new(name, [:named_table, :public, :set])
  end

  defp make_key(name, type, meta), do: {name, type, meta}

  @doc """
  Put the metric information in to the metric table
  """
  @spec put(name(), Mobius.metric_name(), Mobius.metric_type(), integer(), map()) :: :ok
  def put(name, event_name, type, value, meta \\ %{})

  def put(name, event_name, :counter, _value, meta) do
    key = make_key(event_name, :counter, meta)

    # the counter value is located in the second position of the tuple record
    count_position = 2

    # default value for the counter is 0
    default_spec = {count_position, 0}

    :ets.update_counter(name, key, {count_position, 1}, default_spec)

    :ok
  end

  def put(name, event_name, :last_value, value, meta) do
    key = make_key(event_name, :last_value, meta)

    :ets.insert(name, {key, value})

    :ok
  end

  @doc """
  Increment a counter metric
  """
  @spec inc_counter(name(), Mobius.metric_name(), map()) :: :ok
  def inc_counter(name, event_name, meta \\ %{}) do
    put(name, event_name, :counter, 1, meta)
  end

  @doc """
  Get all entries in the table
  """
  @spec get_entries(name()) :: [metric_entry()]
  def get_entries(name) do
    ms = [
      {
        {{:"$1", :"$2", :"$3"}, :"$4"},
        [],
        [{{:"$1", :"$2", :"$4", :"$3"}}]
      }
    ]

    :ets.select(name, ms)
  end

  @doc """
  Get metrics by event name
  """
  @spec get_entries_by_event_name(name(), Mobius.metric_name()) :: [metric_entry()]
  def get_entries_by_event_name(name, event_name) do
    ms = [
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:==, :"$1", event_name}],
       [{{:"$1", :"$2", :"$4", :"$3"}}]}
    ]

    :ets.select(name, ms)
  end
end
