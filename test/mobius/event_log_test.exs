defmodule Mobius.EventLogTest do
  use ExUnit.Case, async: true

  alias Mobius.{Event, EventLog, EventsServer}

  test "gets a list of all the events" do
    gen_events =
      for event_name <- ["a.b.c", "one.two.three", "x.y.z"] do
        ts = System.system_time(:second)
        Event.new(event_name, ts - Enum.random(1..30), %{a: 1}, %{test: true})
      end

    load_event_log(:list_all, gen_events)

    events = EventLog.list(:list_all)

    refute Enum.empty?(events)

    for event <- events do
      assert event.name in ["a.b.c", "one.two.three", "x.y.z"]
    end
  end

  test "to binary works (version 1)" do
    events = [
      Event.new("a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("d.e.f", 123_124, %{a: 1}, %{})
    ]

    load_event_log(:to_binary_works, events)

    expected_bin = <<0x01, :erlang.term_to_binary(events)::binary>>

    bin = EventLog.to_binary(:to_binary_works)

    assert bin == expected_bin
  end

  test "parses version 1" do
    events = [
      Event.new("a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("d.e.f", 123_124, %{a: 1}, %{})
    ]

    bin = <<0x01, :erlang.term_to_binary(events)::binary>>

    {:ok, event_log} = EventLog.parse(bin)

    assert event_log == events
  end

  defp load_event_log(log_name, events) do
    start_supervised!(
      {EventsServer, mobius_instance: log_name, persistence_dir: "/tmp/mobius_event_log_test"}
    )

    Enum.each(events, fn event -> EventsServer.insert(log_name, event) end)
  end
end
