defmodule Mobius.ReportServer do
  @moduledoc false

  # server for building reports

  # Right now we will put this in a singleton that handles both metrics and
  # events for convenience, but if needed we can refactor them into separate
  # servers.

  use GenServer

  alias Mobius.{Event, EventLog, Scraper}

  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    {:via, Registry, {Mobius.ProcessRegistry, {__MODULE__, instance}}}
  end

  @doc """
  Get the latest events
  """
  @spec get_latest_events(Mobius.instance()) :: [Event.t()]
  def get_latest_events(instance) do
    GenServer.call(name(instance), :get_latest_events)
  end

  @doc """
  Get the latest metrics
  """
  @spec get_latest_metrics(Mobius.instance()) :: [Mobius.metric()]
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

    metrics =
      state.instance
      |> Scraper.all(from: from, to: to)
      |> Enum.map(&Scraper.to_metric/1)

    {:reply, metrics, %{state | metrics_next_start: to + 1}}
  end

  defp get_query_window(%{events_next_start: nil}, :events) do
    {0, last_closed_second()}
  end

  defp get_query_window(state, :events) do
    {state.events_next_start, last_closed_second()}
  end

  defp get_query_window(%{metrics_next_start: nil}, :metrics) do
    {0, last_closed_second()}
  end

  defp get_query_window(state, :metrics) do
    {state.metrics_next_start, last_closed_second()}
  end

  # Only query up to the previous (closed) second. Records can still land in
  # the current second after this query has run, and since the next window
  # starts at `to + 1` they would be skipped permanently.
  defp last_closed_second() do
    System.system_time(:second) - 1
  end
end
