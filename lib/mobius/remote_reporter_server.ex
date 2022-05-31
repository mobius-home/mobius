defmodule Mobius.RemoteReporterServer do
  @moduledoc false

  use GenServer

  require Logger

  alias Mobius.{RemoteReporter, Scraper}

  @typedoc """
  Arguments to the client server
  """
  @type arg() ::
          {:reporter, RemoteReporter.t() | {RemoteReporter.t(), term()}}
          | {:report_interval, non_neg_integer()}
          | {:mobius_instance, Mobius.instance()}

  @doc """
  Start the client server
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    instance = Keyword.fetch!(args, :mobius_instance)

    GenServer.start_link(__MODULE__, args, name: name(instance))
  end

  defp name(mobius_instance) do
    Module.concat(__MODULE__, mobius_instance)
  end

  @impl GenServer
  def init(args) do
    instance = args[:mobius_instance] || :mobius
    {reporter, reporter_args} = get_reporter(args)
    {:ok, state} = reporter.init(reporter_args)
    report_interval = args[:report_interval] || 60_000

    timer_ref = Process.send_after(self(), :report, report_interval)

    {:ok,
     %{
       reporter: reporter,
       reporter_state: state,
       report_interval: report_interval,
       interval_ref: timer_ref,
       next_query_from: nil,
       mobius: instance
     }}
  end

  defp get_reporter(args) do
    case Keyword.fetch!(args, :reporter) do
      {reporter, _client_args} = return when is_atom(reporter) -> return
      reporter when is_atom(reporter) -> {reporter, []}
    end
  end

  @impl GenServer
  def handle_info(:report, state) do
    {from, to} = get_query_window(state)
    records = Scraper.all(state.mobius, from: from, to: to)
    new_timer_ref = Process.send_after(self(), :report, state.report_interval)

    case state.reporter.handle_metrics(records, state.reporter_state) do
      {:noreply, new_state} ->
        {:noreply,
         %{
           state
           | reporter_state: new_state,
             next_query_from: to + 1,
             interval_ref: new_timer_ref
         }}
    end
  end

  def get_query_window(%{next_query_from: nil} = state) do
    now = now()
    subtract = div(state.report_interval, 1000)

    {now - subtract, now}
  end

  def get_query_window(state) do
    {state.next_query_from, now()}
  end

  defp now() do
    DateTime.to_unix(DateTime.utc_now(), :second)
  end
end
