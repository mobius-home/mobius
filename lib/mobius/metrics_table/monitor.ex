defmodule Mobius.MetricsTable.Monitor do
  @moduledoc false

  # module to save the metrics table to disk when shutting down Mobius

  use GenServer

  alias Mobius.MetricsTable

  require Logger

  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    Module.concat(__MODULE__, instance)
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(Mobius.instance()) :: :ok | {:error, reason :: term()}
  def save(instance), do: GenServer.call(name(instance), :save)

  @doc """
  Clear all metrics and remove the persisted metrics table file
  """
  @spec reset(Mobius.instance()) :: :ok
  def reset(instance), do: GenServer.call(name(instance), :reset)

  @impl GenServer
  def init(args) do
    Process.flag(:trap_exit, true)

    state =
      args
      |> Keyword.take([:mobius_instance, :persistence_dir])
      |> Enum.into(%{})

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, MetricsTable.reset(state.mobius_instance, state.persistence_dir), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    save_to_persistence(state)
  end

  # Write our ETS table to persistent storage. A failed write is logged and
  # otherwise tolerated — writability can come and go on embedded targets,
  # and the next save attempt retries.
  defp save_to_persistence(state) do
    case MetricsTable.save(state.mobius_instance, state.persistence_dir) do
      :ok ->
        :ok

      error ->
        Logger.warning("[Mobius] Failed to save metrics table because #{inspect(error)}")

        error
    end
  end
end
