defmodule Mobius.Scraper do
  @moduledoc false

  use GenServer

  alias Mobius.{Events, MetricsTable, Persistence, RRD, TimeServer}

  require Logger

  @interval 1_000
  @file_name "history"

  @doc """
  Start the scraper server
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(mobius_instance) do
    {:via, Registry, {Mobius.ProcessRegistry, {__MODULE__, mobius_instance}}}
  end

  @typedoc """
  Options to pass to the all call

  * `:from` - the unix timestamp, in seconds, to start querying form
  * `:to` - the unix timestamp, in seconds, to query to
  """
  @type all_opt() :: {:from, integer()} | {:to, integer()}

  @doc """
  Get all the records

  Returns a flat list of `{timestamp, record}` pairs, where `record` is a packed
  `{name, type, value, tags}` tuple. Callers that need the public
  `t:Mobius.metric/0` map shape should pipe through `to_metric/1`.
  """
  @spec all(Mobius.instance(), [all_opt()]) :: [{Mobius.timestamp(), Mobius.metric_record()}]
  def all(instance, opts \\ []) do
    GenServer.call(name(instance), {:get, opts})
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(Mobius.instance()) :: :ok | {:error, reason :: term()}
  def save(instance), do: GenServer.call(name(instance), :save)

  @doc """
  Clear all in-memory history and remove the persisted history file
  """
  @spec remove_all_data(Mobius.instance()) :: :ok
  def remove_all_data(instance), do: GenServer.call(name(instance), :remove_all_data)

  @impl GenServer
  def init(args) do
    _ = :timer.send_interval(@interval, self(), :scrape)
    Process.flag(:trap_exit, true)

    # Register before asking for the initial value so a sync that lands
    # between the two calls arrives as a message instead of being missed
    # (same order as Mobius.EventsServer).
    :ok = TimeServer.register(args[:mobius_instance], self())

    state =
      args
      |> state_from_args()
      |> Map.put(:synced?, TimeServer.synchronized?(args[:mobius_instance]))
      |> make_database(args)

    {:ok, state}
  end

  defp state_from_args(args) do
    # The resolved sketch configurations ride along with the persisted RRD
    # data so load can detect — and drop — histogram data recorded under a
    # different configuration (bin indices are meaningless under another
    # relative_accuracy).
    args
    |> Keyword.take([:mobius_instance, :persistence_dir])
    |> Enum.into(%{
      histogram_configs: Events.histogram_configs(args[:metrics] || []),
      compression_level: args[:compression_level] || 9
    })
  end

  defp make_database(state, args) do
    # Keep the pristine, empty database around so remove_all_data/1 can
    # discard all stored data while preserving the configured resolution
    # capacities.
    empty = args[:database]
    rrd = load_data(empty, state)

    state
    |> Map.put(:database, rrd)
    |> Map.put(:empty_database, empty)
  end

  defp load_data(database, state) do
    with {:ok, contents} <- File.read(file(state)),
         {:ok, rrd} <-
           RRD.load(database, contents, histogram_configs: state.histogram_configs) do
      rrd
    else
      {:error, :enoent} ->
        database

      {:error, %Mobius.DataLoadError{} = error} ->
        Logger.warning(Exception.message(error))

        database

      {:error, reason} ->
        # e.g. an unreadable or not-yet-mounted persistence dir: start
        # memory-only rather than crash the boot over history.
        Logger.warning("[Mobius] Could not read persisted history because #{inspect(reason)}")

        database
    end
  end

  defp file(state) do
    Path.join(state.persistence_dir, @file_name)
  end

  @typedoc """
  Compact per-scrape histogram payload.

  Outer map keyed by `{metric_name, tags}`. Each entry is one
  `:erlang.term_to_binary/1`-encoded `t:Mobius.DDSketch.snapshot/0` tuple
  (positive bins, negative bins, zero-bucket count). Keeping the payload
  encoded at rest makes the retained scrapes roughly an order of
  magnitude smaller than bin maps and keeps them off the owning process
  heap; `Mobius.DDSketch.from_snapshot/2` decodes it at query time.
  """
  @type histograms() :: %{
          {Mobius.metric_name(), map()} => binary()
        }

  @doc """
  Get the per-scrape histogram payloads in the requested time range.

  Returns a list of `{ts, histograms}` tuples sorted by timestamp.
  Scrapes that captured no histogram bins are still returned with a
  `%{}` payload so callers can position window boundaries.
  """
  @spec all_histograms(Mobius.instance(), [all_opt()]) :: [{integer(), histograms()}]
  def all_histograms(instance, opts \\ []) do
    GenServer.call(name(instance), {:get_histograms, opts})
  end

  @doc """
  Whether the RRD may have discarded its oldest scrapes.

  See `Mobius.RRD.rolled_off?/1`.
  """
  @spec history_rolled_off?(Mobius.instance()) :: boolean()
  def history_rolled_off?(instance) do
    GenServer.call(name(instance), :history_rolled_off?)
  end

  defp to_metrics_list(timestamped_snapshots) do
    Enum.flat_map(timestamped_snapshots, fn
      {ts, {records, _histograms}} -> Enum.map(records, fn record -> {ts, record} end)
      # Tolerate the legacy pre-v3 shape just in case.
      {ts, records} when is_list(records) -> Enum.map(records, fn record -> {ts, record} end)
    end)
  end

  defp to_histograms_list(timestamped_snapshots) do
    Enum.map(timestamped_snapshots, fn
      {ts, {_records, histograms}} -> {ts, histograms}
      {ts, _records} -> {ts, %{}}
    end)
  end

  @doc """
  Materialize a packed record (and its timestamp) into a `Mobius.metric/0` map
  """
  @spec to_metric({Mobius.timestamp(), Mobius.metric_record()}) :: Mobius.metric()
  def to_metric({ts, {name, type, value, tags}}) do
    %{timestamp: ts, name: name, type: type, value: value, tags: tags}
  end

  @impl GenServer
  def handle_call({:get, opts}, _from, state) do
    snapshots = query_snapshots(state, opts)
    {:reply, to_metrics_list(snapshots), state}
  end

  def handle_call({:get_histograms, opts}, _from, state) do
    snapshots = query_snapshots(state, opts)
    {:reply, to_histograms_list(snapshots), state}
  end

  def handle_call(:history_rolled_off?, _from, state) do
    {:reply, RRD.rolled_off?(state.database), state}
  end

  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
  end

  def handle_call(:remove_all_data, _from, state) do
    # Drop the persisted history file so a later save (or the terminate
    # save on shutdown) does not resurrect the data we just cleared.
    _ = File.rm(file(state))
    _ = File.rm(file(state) <> ".tmp")

    {:reply, :ok, %{state | database: state.empty_database}}
  end

  defp query_snapshots(state, opts) do
    case Keyword.get(opts, :from) do
      nil ->
        RRD.all(state.database)

      from ->
        case opts[:to] do
          nil -> RRD.query(state.database, from)
          to -> RRD.query(state.database, from, to)
        end
    end
  end

  @impl GenServer
  # Scrapes taken before the clock synchronizes would carry garbage
  # timestamps (e.g. 1970-era on a device waiting for NTP), so skip them
  # entirely: they would either pollute the RRD or be dropped against the
  # high-water marks of loaded valid history anyway. The metrics table
  # keeps aggregating and recording picks up at the first post-sync scrape.
  def handle_info(:scrape, %{synced?: false} = state) do
    {:noreply, state}
  end

  def handle_info(:scrape, state) do
    case MetricsTable.get_entries(state.mobius_instance) do
      [] ->
        {:noreply, state}

      entries ->
        # The clock is trusted here, so a timestamp far below the high-water
        # marks means the wall clock stepped backwards (or persisted history
        # was recorded under a wrong-ahead clock) and the RRD recovers by
        # pruning everything above it.
        ts = System.system_time(:second)
        snapshot = build_snapshot(entries)
        database = RRD.insert_with_regression_recovery(state.database, ts, snapshot)

        {:noreply, %{state | database: database}}
    end
  end

  def handle_info({Mobius.TimeServer, _sync_timestamp, _adjustment}, state) do
    {:noreply, %{state | synced?: true}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # Split incoming entries into the regular records list and the compact
  # per-metric histogram payload map. See histograms/0.
  defp build_snapshot(entries) do
    {records, hists} =
      Enum.reduce(entries, {[], %{}}, fn entry, {records, hists} ->
        case entry do
          {name, {:hist, :pos, idx}, value, tags} ->
            {records, put_hist_bin(hists, {name, tags}, :positive, idx, value)}

          {name, {:hist, :neg, idx}, value, tags} ->
            {records, put_hist_bin(hists, {name, tags}, :negative, idx, value)}

          {name, {:hist, :zero}, value, tags} ->
            {records, put_zero(hists, {name, tags}, value)}

          {_name, _type, _value, _tags} = record ->
            {[record | records], hists}
        end
      end)

    {records, Map.new(hists, fn {key, snapshot} -> {key, :erlang.term_to_binary(snapshot)} end)}
  end

  defp put_hist_bin(hists, key, region, idx, value) do
    {pos, neg, zero} = Map.get(hists, key, {%{}, %{}, 0})

    case region do
      :positive -> Map.put(hists, key, {Map.put(pos, idx, value), neg, zero})
      :negative -> Map.put(hists, key, {pos, Map.put(neg, idx, value), zero})
    end
  end

  defp put_zero(hists, key, value) do
    {pos, neg, _zero} = Map.get(hists, key, {%{}, %{}, 0})
    Map.put(hists, key, {pos, neg, value})
  end

  @impl GenServer
  def terminate(_reason, state) do
    save_to_persistence(state)
  end

  # Write our database to persistent storage. See Mobius.Persistence for the
  # write-to-tmp + fsync + rename details.
  defp save_to_persistence(state) do
    contents =
      RRD.save(state.database,
        histogram_configs: state.histogram_configs,
        compression_level: state.compression_level
      )

    case Persistence.write_atomic(state.persistence_dir, @file_name, contents) do
      :ok ->
        :ok

      error ->
        Logger.warning("Failed to save metrics history because #{inspect(error)}")

        error
    end
  end
end
