defmodule Mobius.MetricsTable do
  @moduledoc false

  # Table for tracking current state of metrics

  # Internal table object structure
  # {{metric_name, metric_type, metadata}, value}

  # External object structure
  # {name, type, value, meta}

  @typedoc """
  A single entry of a metric in the metric table
  """
  @type metric_entry() ::
          {Telemetry.Metrics.metric_name(), Mobius.metric_type(), integer(), map()}

  require Logger

  alias Mobius.Summary

  @doc """
  Initialize the metrics table
  """
  @spec init([Mobius.arg()]) :: Mobius.instance()
  def init(args) do
    table_name = args[:mobius_instance]

    case read_table_from_file(args) do
      {:ok, table} ->
        table

      {:error, :enoent} ->
        # Metrics save file doesn't (yet) exist
        :ets.new(table_name, [:named_table, :public, :set])

      {:error, reason} ->
        Logger.warn("[Mobius] Could not recover metrics from file because #{inspect(reason)}")
        :ets.new(table_name, [:named_table, :public, :set])
    end
  end

  defp read_table_from_file(args) do
    path = Path.join(args[:persistence_dir], "metrics_table")

    if File.exists?(path) do
      :ets.file2tab(String.to_charlist(path))
    else
      {:error, :enoent}
    end
  end

  defp make_key(name, type, meta), do: {name, type, meta}

  @doc """
  Save the ets table to a file
  """
  @spec save(Mobius.instance(), Path.t()) :: :ok | {:error, reason :: term()}
  def save(instance, persistence_dir) do
    file = String.to_charlist("#{persistence_dir}/metrics_table")

    :ets.tab2file(instance, file)
  end

  @doc """
  Put the metric information in to the metric table
  """
  @spec put(Mobius.instance(), Mobius.metric_name(), Mobius.metric_type(), integer(), map()) ::
          :ok
  def put(table, event_name, type, value, meta \\ %{})

  def put(table, event_name, :counter, _value, meta) do
    key = make_key(event_name, :counter, meta)

    put_counter_type(table, key, 1)

    :ok
  end

  def put(table, event_name, :last_value, value, meta) do
    key = make_key(event_name, :last_value, meta)

    :ets.insert(table, {key, value})

    :ok
  end

  def put(table, metric_name, :sum, value, meta) do
    key = make_key(metric_name, :sum, meta)

    put_counter_type(table, key, value)

    :ok
  end

  def put(table, metric_name, :summary, value, meta) do
    key = make_key(metric_name, :summary, meta)

    summary =
      case :ets.lookup(table, key) do
        [{^key, last_summary}] -> Summary.update(last_summary, value)
        [] -> Summary.new(value)
      end

    :ets.insert(table, {key, summary})

    :ok
  end

  defp put_counter_type(table, key, incr_value) do
    position = 2

    update_spec = {position, incr_value}
    # the default value to add the increment value to if this has not been set
    # yet
    default_spec = {position, 0}

    :ets.update_counter(table, key, update_spec, default_spec)
  end

  @doc """
  Remove a metric from the metric table
  """
  @spec remove(Mobius.instance(), Mobius.metric_name(), Mobius.metric_type(), map()) :: :ok
  def remove(table, metric_name, type, meta \\ %{}) do
    key = make_key(metric_name, type, meta)

    true = :ets.delete(table, key)

    :ok
  end

  @doc """
  Increment a counter metric
  """
  @spec inc_counter(Mobius.instance(), Mobius.metric_name(), map()) :: :ok
  def inc_counter(table, event_name, meta \\ %{}) do
    put(table, event_name, :counter, 1, meta)
  end

  @doc """
  Update a sum metric type
  """
  @spec update_sum(Mobius.instance(), Mobius.metric_name(), integer(), map()) :: :ok
  def update_sum(table, metric_name, value, meta \\ %{}) do
    put(table, metric_name, :sum, value, meta)
  end

  @doc """
  Get all entries in the table
  """
  @spec get_entries(Mobius.instance()) :: [metric_entry()]
  def get_entries(table) do
    ms = [
      {
        {{:"$1", :"$2", :"$3"}, :"$4"},
        [],
        [{{:"$1", :"$2", :"$4", :"$3"}}]
      }
    ]

    :ets.select(table, ms)
  end

  @doc """
  Get metrics by event name
  """
  @spec get_entries_by_event_name(Mobius.instance(), Mobius.metric_name()) :: [metric_entry()]
  def get_entries_by_event_name(table, event_name) do
    ms = [
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:==, :"$1", event_name}],
       [{{:"$1", :"$2", :"$4", :"$3"}}]}
    ]

    :ets.select(table, ms)
  end
end
