defmodule Mobius.MetricsTable do
  @moduledoc false

  # Table for tracking current state of metrics

  # MetricTable object structure
  # {{normalize_metric_name, metric_type, metadata}, value}

  @typedoc """
  A single entry of a metric in the metric table
  """
  @type metric_entry() ::
          {Mobius.metric_name(), Mobius.metric_type(), integer(), map()}

  require Logger

  alias Mobius.{Events, Summary}
  alias Telemetry.Metrics

  # Meta row carrying the resolved sketch configuration the histogram bin
  # counters were recorded under. Metric rows are keyed by a 3-tuple, so
  # this atom key is invisible to the get_entries match specs and rides
  # along in the tab2file dump for free.
  @histogram_configs_key :__histogram_configs__

  @doc """
  Initialize the metrics table
  """
  @spec init([Mobius.arg()]) :: Mobius.instance()
  def init(args) do
    table_name = args[:mobius_instance]
    configs = Events.histogram_configs(args[:metrics] || [])

    table =
      case read_table_from_file(args) do
        {:ok, table} ->
          reconcile_histogram_bins(table, configs)
          table

        {:error, :enoent} ->
          # Metrics save file doesn't (yet) exist
          :ets.new(table_name, [:named_table, :public, :set])

        {:error, reason} ->
          Logger.warning(
            "[Mobius] Could not recover metrics from file because #{inspect(reason)}"
          )

          :ets.new(table_name, [:named_table, :public, :set])
      end

    :ets.insert(table, {@histogram_configs_key, configs})
    table
  end

  # Drop restored histogram bin rows whose sketch configuration no longer
  # matches the one they were recorded under — bin indices are meaningless
  # under a different configuration, and leaving them in place would mix
  # two index spaces in the same cumulative counters. Restored dumps that
  # predate the config meta row are treated as unverifiable and dropped.
  defp reconcile_histogram_bins(table, current_configs) do
    persisted_configs =
      case :ets.lookup(table, @histogram_configs_key) do
        [{@histogram_configs_key, configs}] -> configs
        [] -> %{}
      end

    keys = :ets.select(table, [{{{:"$1", :"$2", :"$3"}, :_}, [], [{{:"$1", :"$2", :"$3"}}]}])

    dropped =
      Enum.reduce(keys, MapSet.new(), fn
        {name, type, meta} = key, dropped when elem(type, 0) == :hist ->
          config_key = {Enum.join(name, "."), meta |> Map.keys() |> Enum.sort()}
          current = Map.get(current_configs, config_key)

          if current != nil and Map.get(persisted_configs, config_key) == current do
            dropped
          else
            :ets.delete(table, key)
            MapSet.put(dropped, config_key)
          end

        _key, dropped ->
          dropped
      end)

    if MapSet.size(dropped) > 0 do
      Logger.warning(
        "[Mobius] Dropping restored histogram bin counters for " <>
          "#{inspect(MapSet.to_list(dropped))}: sketch configuration changed or " <>
          "histograms no longer enabled for the metric"
      )
    end

    :ok
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
  Put the metric information into the metric table
  """
  @spec put(
          Mobius.instance(),
          Metrics.normalized_metric_name(),
          Mobius.metric_type(),
          integer(),
          map()
        ) ::
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
  @spec remove(Mobius.instance(), Metrics.normalized_metric_name(), Mobius.metric_type(), map()) ::
          :ok
  def remove(table, metric_name, type, meta \\ %{}) do
    key = make_key(metric_name, type, meta)

    true = :ets.delete(table, key)

    :ok
  end

  @doc """
  Increment a counter metric
  """
  @spec inc_counter(Mobius.instance(), Metrics.normalized_metric_name(), map()) :: :ok
  def inc_counter(table, event_name, meta \\ %{}) do
    put(table, event_name, :counter, 1, meta)
  end

  @doc """
  Update a sum metric type
  """
  @spec update_sum(Mobius.instance(), Metrics.normalized_metric_name(), integer(), map()) :: :ok
  def update_sum(table, metric_name, value, meta \\ %{}) do
    put(table, metric_name, :sum, value, meta)
  end

  @doc """
  Increment a histogram bin counter.

  Histogram bins back the `Mobius.DDSketch` representation: each populated
  bin is one ETS counter row. `bin_key` is one of the tuples produced by
  `Mobius.DDSketch.bin_key_for_value/2`:

    * `{:hist, :pos, idx}` — positive value bin
    * `{:hist, :neg, idx}` — negative value bin
    * `{:hist, :zero}` — values folded into the zero bucket

  This is a counter-style write, so it inherits every resilience property
  the existing counter type has: ingress-time aggregation, snapshot via
  `get_entries/1`, persistence via the regular `tab2file` dump.
  """
  @spec inc_histogram_bin(
          Mobius.instance(),
          Metrics.normalized_metric_name(),
          Mobius.DDSketch.bin_key(),
          map(),
          pos_integer()
        ) :: :ok
  def inc_histogram_bin(table, metric_name, bin_key, meta \\ %{}, count \\ 1)
      when is_integer(count) and count > 0 do
    key = make_key(metric_name, bin_key, meta)
    _ = put_counter_type(table, key, count)
    :ok
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

    table
    |> :ets.select(ms)
    |> Enum.map(fn {name, type, value, tags} ->
      {normalized_name_to_string(name), type, value, tags}
    end)
  end

  @doc """
  Get metrics by event name
  """
  @spec get_entries_by_metric_name(Mobius.instance(), Mobius.metric_name()) :: [metric_entry()]
  def get_entries_by_metric_name(table, metric_name) do
    normalized_name =
      metric_name
      |> String.split(".", trim: true)
      |> Enum.map(&String.to_existing_atom/1)

    ms = [
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:==, :"$1", normalized_name}],
       [{{:"$1", :"$2", :"$4", :"$3"}}]}
    ]

    table
    |> :ets.select(ms)
    |> Enum.map(fn {name, type, value, tags} ->
      {normalized_name_to_string(name), type, value, tags}
    end)
  end

  defp normalized_name_to_string(normalized_name) do
    Enum.join(normalized_name, ".")
  end
end
