defmodule Mobius.EventLogTest do
  use ExUnit.Case, async: true

  alias Mobius.{Event, EventLog, EventsServer}

  @tag :tmp_dir
  test "gets a list of all the events", %{tmp_dir: tmp_dir} do
    gen_events =
      for event_name <- ["a.b.c", "one.two.three", "x.y.z"] do
        ts = System.system_time(:second)
        Event.new("test", event_name, ts - Enum.random(1..30), %{a: 1}, %{test: true})
      end

    load_event_log(:list_all, tmp_dir, gen_events)

    events = EventLog.list(instance: :list_all)

    refute Enum.empty?(events)

    for event <- events do
      assert event.name in ["a.b.c", "one.two.three", "x.y.z"]
    end
  end

  @tag :tmp_dir
  test "to_binary round-trips through parse/1", %{tmp_dir: tmp_dir} do
    events = [
      Event.new("test", "a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("test", "d.e.f", 123_124, %{a: 1}, %{})
    ]

    load_event_log(:to_binary_works, tmp_dir, events)

    bin = EventLog.to_binary(instance: :to_binary_works)

    assert <<0x01, _payload::binary>> = bin
    assert {:ok, ^events} = EventLog.parse(bin)
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

  test "parse/1 returns an error tuple for a corrupt v1 payload" do
    assert {:error, _reason} = EventLog.parse(<<0x01, 255, 254, 253, 252>>)
  end

  test "parse/1 rejects a v1 payload that is not a list of events" do
    assert {:error, _reason} = EventLog.parse(<<0x01, :erlang.term_to_binary(:boom)::binary>>)
  end

  @tag capture_log: true
  test "parse/1 drops entries that are not the current Event struct" do
    event = Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1)
    bin = <<0x01, :erlang.term_to_binary([event, %{not: :an_event}, :junk])::binary>>

    assert {:ok, [^event]} = EventLog.parse(bin)
  end

  @tag :tmp_dir
  test "save persists the event log so a fresh instance restores it", %{tmp_dir: tmp_dir} do
    instance = :event_log_roundtrip

    events = [
      Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
      Event.new("test", "d.e.f", %{a: 2}, %{}, timestamp: 2)
    ]

    start_supervised!({Mobius, mobius_instance: instance, persistence_dir: tmp_dir})
    Enum.each(events, fn event -> EventsServer.insert(instance, event) end)

    assert :ok = EventLog.save(instance: instance)

    # The dump landed at the real path with no temp file left behind.
    # Mobius nests persistence under a per-instance subdirectory.
    persistence_path = Path.join(tmp_dir, to_string(instance))
    assert File.exists?(Path.join(persistence_path, "event_log"))
    refute File.exists?(Path.join(persistence_path, "event_log.tmp"))

    stop_supervised!(Mobius)

    # A fresh instance pointed at the same dir recovers the events from disk.
    start_supervised!({Mobius, mobius_instance: instance, persistence_dir: tmp_dir})

    assert EventLog.list(instance: instance) == events
  end

  test "parse/1 accepts uncompressed v1 payloads (backwards compat)" do
    events = [
      Event.new("test", "a.b.c", 123_123, %{a: 1}, %{}),
      Event.new("test", "d.e.f", 123_124, %{a: 1}, %{})
    ]

    bin = <<0x01, :erlang.term_to_binary(events)::binary>>

    assert {:ok, ^events} = EventLog.parse(bin)
  end

  defp load_event_log(log_name, dir, events) do
    start_supervised!({Mobius, mobius_instance: log_name, persistence_dir: dir})

    Enum.each(events, fn event -> EventsServer.insert(log_name, event) end)
  end

  describe "form and to options" do
    @tag :tmp_dir
    test "default: all events", %{tmp_dir: tmp_dir} do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}),
        Event.new("test", "d.e.f", %{a: 1}, %{})
      ]

      load_event_log(:default_from_and_to, tmp_dir, events)

      logged_events = EventLog.list(instance: :default_from_and_to)

      assert logged_events == events
    end

    @tag :tmp_dir
    test "filter from", %{tmp_dir: tmp_dir} do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{})
      ]

      load_event_log(:filter_event_from, tmp_dir, events)

      logged_events = EventLog.list(instance: :filter_event_from, from: 2)
      last_event = List.last(events)

      assert logged_events == [last_event]
    end

    @tag :tmp_dir
    test "filter with to", %{tmp_dir: tmp_dir} do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{}, timestamp: 50),
        Event.new("test", "g.h.i", %{a: 1}, %{}, timestamp: 100)
      ]

      load_event_log(:filter_event_to, tmp_dir, events)

      logged_events = EventLog.list(instance: :filter_event_to, to: 50)

      assert logged_events == Enum.take(events, 2)
    end

    @tag :tmp_dir
    test "filter by group", %{tmp_dir: tmp_dir} do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, group: :network, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{}, timestamp: 2),
        Event.new("test", "g.h.i", %{a: 1}, %{}, group: :network, timestamp: 3)
      ]

      load_event_log(:filter_event_group, tmp_dir, events)

      logged_events = EventLog.list(instance: :filter_event_group, group: :network)

      assert logged_events == [List.first(events), List.last(events)]
    end

    @tag :tmp_dir
    test "provide complete time window", %{tmp_dir: tmp_dir} do
      events = [
        Event.new("test", "a.b.c", %{a: 1}, %{}, timestamp: 1),
        Event.new("test", "d.e.f", %{a: 1}, %{}, timestamp: 50),
        Event.new("test", "g.h.i", %{a: 1}, %{}, timestamp: 55),
        Event.new("test", "j.k.l", %{a: 1}, %{}, timestamp: 99),
        Event.new("test", "m.n.o", %{a: 1}, %{}, timestamp: 100)
      ]

      load_event_log(:filter_event_from_to_window, tmp_dir, events)

      logged_events = EventLog.list(instance: :filter_event_from_to_window, from: 50, to: 99)

      assert logged_events == Enum.drop(events, 1) |> Enum.take(3)
    end
  end
end
