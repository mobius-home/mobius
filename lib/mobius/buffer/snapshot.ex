defmodule Mobius.Buffer.Snapshot do
  @moduledoc false

  # A process to that take a snapshot of the metrics state and stores them for
  # some amount of time.

  use GenServer

  alias Mobius.{Buffer, MetricsTable, Resolutions}

  @typedoc """
  Arguments to start a snapshot server

  * `:resolution` - the resolution a snapshot should run
  * `:name` - the name of the mobius instance
  """
  @type arg() :: {:resolution, Mobius.resolution()} | {:name, atom()}

  @doc """
  Start the snapshot server
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    resolution = Keyword.get(args, :resolution)
    name = Keyword.fetch!(args, :name)
    interval = Resolutions.resolution_interval(resolution)

    _ = :timer.send_interval(interval, self(), :snapshot)

    {:ok, %{resolution: resolution, name: name}}
  end

  @impl GenServer
  def handle_info(:snapshot, state) do
    metrics = MetricsTable.get_entries(state.name)

    Buffer.insert(state.name, state.resolution, DateTime.utc_now(), metrics)

    {:noreply, state}
  end
end
