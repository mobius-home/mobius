defmodule Mobius.ReportServerTest do
  use ExUnit.Case, async: false

  alias Mobius.{Event, EventLog, EventsServer, ReportServer}

  @instance :report_server_test
  @persistence_dir System.tmp_dir!() |> Path.join("mobius_report_server_test")

  setup do
    File.rm_rf!(@persistence_dir)
    File.mkdir_p!(@persistence_dir)

    start_supervised!(
      {Mobius, mobius_instance: @instance, persistence_dir: @persistence_dir, metrics: []}
    )

    :ok
  end

  test "an event landing late in the boundary second is not skipped" do
    # Run a query during a known second so we know which window boundary the
    # server stored. Retry in the unlikely case the second ticks over mid-call.
    boundary =
      Enum.find_value(1..10, fn _ ->
        pre = System.system_time(:second)
        _ = ReportServer.get_latest_events(@instance)
        if System.system_time(:second) == pre, do: pre
      end)

    assert boundary, "could not run a query within a single second"

    # The event lands in second `boundary` *after* the query above ran.
    event = Event.new("test", "late.event", %{value: 1}, %{}, timestamp: boundary)
    :ok = EventsServer.insert(@instance, event)

    # Sanity check: the event is in the event log.
    assert Enum.any?(EventLog.list(instance: @instance), &(&1.name == "late.event"))

    # Once the boundary second has fully passed, the next report must still
    # pick the event up — it must not fall between the query windows.
    wait_until_after(boundary)

    events = ReportServer.get_latest_events(@instance)

    assert Enum.any?(events, &(&1.name == "late.event"))
  end

  defp wait_until_after(second) do
    if System.system_time(:second) <= second do
      Process.sleep(50)
      wait_until_after(second)
    end
  end
end
