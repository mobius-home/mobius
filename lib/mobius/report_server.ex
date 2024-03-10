defmodule Mobius.ReportServer do
  @moduledoc false

  # server for building reports

  # Right now we will put this in a singleton that handles both metrics and
  # events for convenience, but if needed we can refactor them into separate
  # servers.

  use GenServer

  alias Mobius.{Event, EventLog, Scraper}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    Module.concat(__MODULE__, instance)
  end

  @doc """
  Get the latest events
  """
  @spec get_latest_events(Mobius.instance()) :: [Event.t()]
  def get_latest_events(instance) do
    GenServer.call(name(instance), :get_latest_events)
  end

  def get_latest_metrics(instance) do
    GenServer.call(name(instance), :get_latest_metrics)
  end

  @impl GenServer
  def init(args) do
    {:ok, %{instance: args[:mobius_instance], events_next_start: nil, metrics_next_start: nil}}
  end

  @impl GenServer
  def handle_call(:get_latest_events, _from, state) do
    {from, to} = get_query_window(state, :events)

    events = EventLog.list(instance: state.instance, from: from, to: to)

    {:reply, events, %{state | events_next_start: to + 1}}
  end

  def handle_call(:get_latest_metrics, _from, state) do
    {from, to} = get_query_window(state, :metrics)

    metrics = Scraper.all(state.instance, from: from, to: to)

    {:reply, metrics, %{state | metrics_next_start: to + 1}}
  end

  defp get_query_window(%{events_next_start: nil}, :events) do
    {0, now()}
  end

  defp get_query_window(state, :events) do
    {state.events_next_start, now()}
  end

  defp get_query_window(%{metrics_next_start: nil}, :metrics) do
    {0, now()}
  end

  defp get_query_window(state, :metrics) do
    {state.metrics_next_start, now()}
  end

  defp now() do
    System.system_time(:second)
  end
end
