defmodule Mobius.History do
  @moduledoc """
  View the historicial information about metric data
  """

  use GenServer

  alias Mobius.MetricsTable

  @typedoc """
  A historicial record of the what values the metrics contained at a
  particualar time.
  """
  @type record() :: {DateTime.t(), [MetricsTable.entry()]}

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  View the metric history recorded by Mobius
  """
  @spec view() :: [record()]
  def view() do
    GenServer.call(__MODULE__, :view)
  end

  @impl GenServer
  def init(args) do
    metrics_table = Keyword.get(args, :table_name)
    buffer_size = Keyword.get(args, :history_size, 500)
    snapshot_interval = Keyword.get(args, :snapshot_interval, 1_000)

    buffer = CircularBuffer.new(buffer_size)
    interval = :timer.send_interval(snapshot_interval, self(), :record)

    {:ok, %{buffer: buffer, table: metrics_table, interval: interval}}
  end

  @impl GenServer
  def handle_call(:view, _from, state) do
    history = CircularBuffer.to_list(state.buffer)

    {:reply, history, state}
  end

  @impl GenServer
  def handle_info(:record, state) do
    metrics = MetricsTable.get_entries(state.table)
    new_buffer = CircularBuffer.insert(state.buffer, {DateTime.utc_now(), metrics})

    {:noreply, %{state | buffer: new_buffer}}
  end
end
