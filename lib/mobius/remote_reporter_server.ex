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
    start_time = System.monotonic_time(:second)
    report_interval = args[:report_interval]

    state =
      %{
        reporter: reporter,
        reporter_state: state,
        report_interval: report_interval,
        next_query_from: nil,
        mobius: instance,
        start_time: start_time
      }
      |> maybe_start_interval()

    {:ok, state}
  end

  defp get_reporter(args) do
    case Keyword.fetch!(args, :reporter) do
      {reporter, _client_args} = return when is_atom(reporter) -> return
      reporter when is_atom(reporter) -> {reporter, []}
    end
  end

  @doc """
  Report the latest metrics

  This function will for the latest metrics to be reported. This is useful for
  programmatic or manually control for metrics reporting.
  """
  @spec report_metrics(Mobius.instance()) :: :ok
  def report_metrics(mobius_instance \\ :mobius) do
    name = name(mobius_instance)

    GenServer.cast(name, :report_metrics)
  end

  @impl GenServer
  def handle_cast(:report_metrics, state) do
    {:noreply, run_report(state)}
  end

  @impl GenServer
  def handle_info(:report, state) do
    {:noreply, run_report(state)}
  end

  defp run_report(state) do
    {from, to} = get_query_window(state)
    records = Scraper.all(state.mobius, from: from, to: to)

    case state.reporter.handle_metrics(records, state.reporter_state) do
      {:noreply, new_state} ->
        %{
          state
          | reporter_state: new_state,
            next_query_from: to + 1
        }
        |> maybe_start_interval()

      {:error, _reason, new_state} ->
        state = %{state | reporter_state: new_state}

        maybe_start_interval(state)
    end
  end

  # if there is not a report interval and a report has not been sent yet
  defp get_query_window(%{report_interval: nil, next_query_from: nil} = state) do
    now_monotonic_time = System.monotonic_time(:second)
    # the amount of time (seconds) that has pass between starting the server
    # wanting to send the report to calculate the from timestamp.
    time_passed = now_monotonic_time - state.start_time
    now_time = now()

    {now_time - time_passed, now_time}
  end

  # if there is not a report interval
  defp get_query_window(%{report_interval: nil} = state) do
    {state.next_query_from, now()}
  end

  defp get_query_window(%{next_query_from: nil} = state) do
    now = now()
    subtract = div(state.report_interval, 1000)

    {now - subtract, now}
  end

  defp get_query_window(state) do
    {state.next_query_from, now()}
  end

  defp now() do
    DateTime.to_unix(DateTime.utc_now(), :second)
  end

  defp maybe_start_interval(state) do
    if state.report_interval do
      timer_ref = Process.send_after(self(), :report, state.report_interval)

      Map.put(state, :interval_ref, timer_ref)
    else
      state
    end
  end
end
