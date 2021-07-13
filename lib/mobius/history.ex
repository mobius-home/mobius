defmodule Mobius.History do
  @moduledoc false

  use GenServer

  alias Mobius.Metrics.History

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
    history = History.init(args)
    :timer.send_interval(history.interval, self(), :record)

    {:ok, history}
  end

  @impl GenServer
  def handle_call(:view, _from, history) do
    {:reply, History.view(history), history}
  end

  @impl GenServer
  def handle_info(:record, history) do
    {:noreply, History.snapshot(history, DateTime.utc_now())}
  end
end
