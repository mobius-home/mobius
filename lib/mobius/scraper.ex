defmodule Mobius.Scraper do
  @moduledoc false

  use GenServer
  require Logger

  alias Mobius.{MetricsTable, RRD}

  @interval 1_000

  @doc """
  Start the scraper server
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:name]))
  end

  defp name(mobius_name) do
    Module.concat(__MODULE__, mobius_name)
  end

  @typedoc """
  Options to pass to the all call

  * `:from` - the unix timestamp, in seconds, to start querying form
  * `:to` - the unix timestamp, in seconds, to query to
  """
  @type all_opt() :: {:from, integer()} | {:to, integer()}

  @doc """
  Get all the records
  """
  @spec all(Mobius.name(), [all_opt()]) :: [Mobius.record()]
  def all(name, opts \\ []) do
    GenServer.call(name(name), {:get, opts})
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(Mobius.name()) :: :ok | {:error, reason :: term()}
  def save(name), do: GenServer.call(name(name), :save)

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
    |> Keyword.take([:name, :persistence_dir])
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
        Logger.warn(Exception.message(error))

        database
    end
  end

  defp file(state) do
    Path.join(state.persistence_dir, "history")
  end

  @impl GenServer
  def handle_call({:get, opts}, _from, state) do
    case Keyword.get(opts, :from) do
      nil ->
        {:reply, RRD.all(state.database), state}

      from ->
        {:reply, query_database(from, state, opts), state}
    end
  end

  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
  end

  defp query_database(from, state, opts) do
    case opts[:to] do
      nil ->
        RRD.query(state.database, from)

      to ->
        RRD.query(state.database, from, to)
    end
  end

  @impl GenServer
  def handle_info(:scrape, state) do
    case MetricsTable.get_entries(state.name) do
      [] ->
        {:noreply, state}

      scrape ->
        ts = System.system_time(:second)
        database = RRD.insert(state.database, ts, scrape)

        {:noreply, %{state | database: database}}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
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
        Logger.warn("Failed to save metrics history because #{inspect(error)}")

        error
    end
  end
end
