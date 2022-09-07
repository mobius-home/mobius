defmodule Mobius.EventLogTest do
  use ExUnit.Case, async: true

  alias Mobius.{Event, EventLog, EventsServer}

  test "gets a list of all the events" do
    gen_events =
      for event_name <- ["a.b.c", "one.two.three", "x.y.z"] do
        ts = System.system_time(:second)
        Event.new("test", event_name, ts - Enum.random(1..30), %{a: 1}, %{test: true})
      end

    load_event_log(:list_all, gen_events)

    events = EventLog.list(instance: :list_all)

    refute Enum.empty?(events)

    for event <- events do
      assert event.name in ["a.b.c", "one.two.three", "x.y.z"]
    end
  end

  test "to binary works (version 1)" do
    events = [
      Event.new("test", "a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("test", "d.e.f", 123_124, %{a: 1}, %{})
    ]

    load_event_log(:to_binary_works, events)

    expected_bin = <<0x01, :erlang.term_to_binary(events)::binary>>

    bin = EventLog.to_binary(instance: :to_binary_works)

    assert bin == expected_bin
  end

  test "parses version 1" do
    events = [
      Event.new("test", "a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("test", "d.e.f", 123_124, %{a: 1}, %{})
    ]

    bin = <<0x01, :erlang.term_to_binary(events)::binary>>

    {:ok, event_log} = EventLog.parse(bin)

    assert event_log == events
  end

  defp load_event_log(log_name, events) do
    start_supervised!(
      {Mobius, mobius_instance: log_name, persistence_dir: "/tmp/mobius_event_log_test"}
    )

    Enum.each(events, fn event -> EventsServer.insert(log_name, event) end)
  end

  describe "form and to options" do
    test "default: all events" do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}),
        Event.new("test", "d.e.f", %{a: 1}, %{})
      ]

      load_event_log(:default_from_and_to, events)

      logged_events = EventLog.list(instance: :default_from_and_to)

      assert logged_events == events
    end

    test "filter from" do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{})
      ]

      load_event_log(:filter_event_from, events)

      logged_events = EventLog.list(instance: :filter_event_from, from: 2)
      last_event = List.last(events)

      assert logged_events == [last_event]
    end

    test "filter with to" do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{}, timestamp: 50),
        Event.new("test", "g.h.i", %{a: 1}, %{}, timestamp: 100)
      ]

      load_event_log(:filter_event_to, events)

      logged_events = EventLog.list(instance: :filter_event_to, to: 50)

      assert logged_events == Enum.take(events, 2)
    end

    test "provide complete time window" do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{}, timestamp: 50),
        Event.new("test", "g.h.i", %{a: 1}, %{}, timestamp: 55),
        Event.new("test", "j.k.l", %{a: 1}, %{}, timestamp: 99),
        Event.new("test", "m.n.o", %{a: 1}, %{}, timestamp: 100)
      ]

      load_event_log(:filter_event_from_to_window, events)

      logged_events = EventLog.list(instance: :filter_event_from_to_window, from: 50, to: 99)

      assert logged_events == Enum.drop(events, 1) |> Enum.take(3)
    end
  end
end
