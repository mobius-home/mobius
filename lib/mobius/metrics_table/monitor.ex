defmodule Mobius.MetricsTable.Monitor do
  @moduledoc false

  # module to save the metrics table to disk when shutting down Mobius

  use GenServer

  alias Mobius.MetricsTable

  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:name]))
  end

  defp name(mobius_name) do
    Module.concat(__MODULE__, mobius_name)
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(Mobius.name()) :: :ok | {:error, reason :: term()}
  def save(name), do: GenServer.call(name(name), :save)

  @impl GenServer
  def init(args) do
    Process.flag(:trap_exit, true)

    state =
      args
      |> Keyword.take([:name, :persistence_dir])
      |> Enum.into(%{})

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:save, _from, state) do
    {:reply, save_to_persistence(state), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    save_to_persistence(state)
  end

  # Write our ETS table to persistent storage
  defp save_to_persistence(state) do
    MetricsTable.save(state.name, state.persistence_dir)
  end
end
