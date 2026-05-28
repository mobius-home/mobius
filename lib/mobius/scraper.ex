defmodule Mobius.Scraper do
  @moduledoc false

  use GenServer

  alias Mobius.{MetricsTable, RRD}

  require Logger

  @interval 1_000

  @doc """
  Start the scraper server
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(mobius_instance) do
    Module.concat(__MODULE__, mobius_instance)
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

  @impl GenServer
  def init(args) do
    _ = :timer.send_interval(@interval, self(), :scrape)
    Process.flag(:trap_exit, true)

    state =
      args
      |> state_from_args()
      |> make_database(args)

    {:ok, state}
  end

  defp state_from_args(args) do
    args
    |> Keyword.take([:mobius_instance, :persistence_dir])
    |> Enum.into(%{})
  end

  defp make_database(state, args) do
    rrd =
      args[:database]
      |> load_data(state)

    Map.put(state, :database, rrd)
  end

  defp load_data(database, state) do
    with {:ok, contents} <- File.read(file(state)),
         {:ok, rrd} <- RRD.load(database, contents) do
      rrd
    else
      {:error, :enoent} ->
        database

      {:error, %Mobius.DataLoadError{} = error} ->
        Logger.warning(Exception.message(error))

        database
    end
  end

  defp file(state) do
    Path.join(state.persistence_dir, "history")
  end

  @typedoc """
  Compact per-snapshot histogram payload.

  Outer map keyed by `{metric_name, tags}`. Each entry is a 3-tuple of
  positive bins (`%{idx => count}`), negative bins, and the zero-bucket
  count. Mirrors the field shape of `t:Mobius.DDSketch.t/0` so the query
  path reconstructs a sketch with one struct update.
  """
  @type histograms_sidecar() :: %{
          {Mobius.metric_name(), map()} =>
            {%{integer() => pos_integer()}, %{integer() => pos_integer()}, non_neg_integer()}
        }

  @doc """
  Get the per-snapshot histogram sidecars in the requested time range.

  Returns a list of `{ts, sidecar}` tuples sorted by timestamp. Empty
  sidecars (snapshots that captured no histogram bins) are still
  returned with a `%{}` payload so callers can position window
  boundaries.
  """
  @spec all_histograms(Mobius.instance(), [all_opt()]) :: [{integer(), histograms_sidecar()}]
  def all_histograms(instance, opts \\ []) do
    GenServer.call(name(instance), {:get_histograms, opts})
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

  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
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
  def handle_info(:scrape, state) do
    case MetricsTable.get_entries(state.mobius_instance) do
      [] ->
        {:noreply, state}

      entries ->
        ts = System.system_time(:second)
        snapshot = build_snapshot(entries)
        database = RRD.insert(state.database, ts, snapshot)

        {:noreply, %{state | database: database}}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # Split incoming entries into the regular records list and the compact
  # per-metric histogram sidecar. See histograms_sidecar/0.
  defp build_snapshot(entries) do
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

  # Write our database to persistent storage
  defp save_to_persistence(state) do
    contents = RRD.save(state.database)

    case File.write(file(state), contents) do
      :ok ->
        :ok

      error ->
        Logger.warning("Failed to save metrics history because #{inspect(error)}")

        error
    end
  end
end
