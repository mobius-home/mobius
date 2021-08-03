defmodule Mobius.Scraper do
  @moduledoc false

  use GenServer
  require Logger

  alias Mobius.{History, MetricsTable}

  @type record() ::
          {integer(),
           [
             {:telemetry.event_name(), Mobius.metric_type(), :telemetry.event_value(),
              :telemetry.event_metadata()}
           ]}

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

  @doc """
  Get all the records
  """
  @spec all(Mobius.name()) :: [record()]
  def all(name) do
    GenServer.call(name(name), :get)
  end

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
    case File.read(file(state)) do
      {:error, :enoent} ->
        tlb

      {:ok, contents} ->
        {:ok, tlb} = History.load(tlb, contents)
        tlb
    end
  end

  defp file(state) do
    Path.join(state.persistence_dir, "history")
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, History.all(state.history), state}
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
