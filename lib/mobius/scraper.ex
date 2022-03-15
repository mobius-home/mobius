defmodule Mobius.Scraper do
  @moduledoc false

  use GenServer
  require Logger

  alias Mobius.{History, MetricsTable}

  @interval 1_000

  @doc """
  Start the history server
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
      |> make_history(args)

    {:ok, state}
  end

  defp state_from_args(args) do
    args
    |> Keyword.take([:name, :persistence_dir])
    |> Enum.into(%{})
  end

  defp make_history(state, args) do
    tlb =
      args
      |> History.new()
      |> load_history(state)

    Map.put(state, :history, tlb)
  end

  defp load_history(tlb, state) do
    with {:ok, contents} <- File.read(file(state)),
         {:ok, tlb} <- History.load(tlb, contents) do
      tlb
    else
      {:error, :enoent} ->
        tlb

      error ->
        Logger.warn("Error reading history file because #{inspect(error)}, ignoring")

        tlb
    end
  end

  defp file(state) do
    Path.join(state.persistence_dir, "history")
  end

  @impl GenServer
  def handle_call({:get, opts}, _from, state) do
    case Keyword.get(opts, :from) do
      nil ->
        {:reply, History.all(state.history), state}

      from ->
        {:reply, query_history(from, state, opts), state}
    end
  end

  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
  end

  defp query_history(from, state, opts) do
    case opts[:to] do
      nil ->
        History.query(state.history, from)

      to ->
        History.query(state.history, from, to)
    end
  end

  @impl GenServer
  def handle_info(:scrape, state) do
    case MetricsTable.get_entries(state.name) do
      [] ->
        {:noreply, state}

      scrape ->
        ts = System.system_time(:second)
        history = History.insert(state.history, ts, scrape)

        {:noreply, %{state | history: history}}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    save_to_persistence(state)
  end

  # Write our history to persistent storage
  defp save_to_persistence(state) do
    contents = History.save(state.history)

    case File.write(file(state), contents) do
      :ok ->
        :ok

      error ->
        Logger.warn("Failed to save metrics history because #{inspect(error)}")

        error
    end
  end
end
