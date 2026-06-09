defmodule Mobius.ScraperTest do
  use ExUnit.Case, async: false

  alias Mobius.{MetricsTable, RRD, Scraper, TimeServer}

  @rrd_args [days: 60, hours: 48, minutes: 120, seconds: 120]

  defmodule FakeClock do
    @moduledoc false

    # The TimeServer polls from its own process, so the flippable answer
    # lives in :persistent_term rather than test process state.
    @behaviour Mobius.Clock

    @key {__MODULE__, :synchronized?}

    def set(synchronized?), do: :persistent_term.put(@key, synchronized?)

    def clear(), do: :persistent_term.erase(@key)

    @impl Mobius.Clock
    def synchronized?(), do: :persistent_term.get(@key, false)
  end

  setup do
    persistence_dir =
      Path.join(System.tmp_dir!(), "mobius_scraper_#{System.unique_integer([:positive])}")

    File.mkdir_p!(persistence_dir)
    on_exit(fn -> File.rm_rf!(persistence_dir) end)

    {:ok, persistence_dir: persistence_dir}
  end

  defp start_scraper(instance, persistence_dir, database, opts \\ []) do
    # The scrape timer reads from a metrics table named after the instance, so
    # make sure it exists before the scraper starts.
    if :ets.whereis(instance) == :undefined do
      MetricsTable.init(mobius_instance: instance, persistence_dir: persistence_dir)
    end

    args =
      [
        mobius_instance: instance,
        persistence_dir: persistence_dir,
        database: database
      ] ++ opts

    # The scraper registers with its instance's TimeServer at boot, so one
    # must be running (the Mobius supervisor starts it first in production).
    if Registry.lookup(Mobius.ProcessRegistry, {TimeServer, instance}) == [] do
      start_supervised!({TimeServer, args})
    end

    pid = start_supervised!({Scraper, args})
    {pid, instance}
  end

  test "scrapes immediately at start instead of waiting an interval", %{
    persistence_dir: persistence_dir
  } do
    instance = :scraper_immediate
    MetricsTable.init(mobius_instance: instance, persistence_dir: persistence_dir)
    MetricsTable.put(instance, [:scrape, :immediate, :test], :last_value, 42)

    {_pid, ^instance} = start_scraper(instance, persistence_dir, RRD.new(@rrd_args))

    # Well under the 1 s first timer tick, so only the boot-time scrape
    # can satisfy this.
    records = poll_for_records(instance, 500)

    assert [{_ts, {"scrape.immediate.test", :last_value, 42, %{}}} | _rest] = records
  end

  test "clamps a sub-second :scrape_interval to the one-second floor", %{
    persistence_dir: persistence_dir
  } do
    instance = :scraper_clamped_interval
    MetricsTable.init(mobius_instance: instance, persistence_dir: persistence_dir)
    MetricsTable.put(instance, [:scrape, :clamp, :test], :last_value, 1)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {_pid, ^instance} =
          start_scraper(instance, persistence_dir, RRD.new(@rrd_args), scrape_interval: 50)

        assert [_ | _] = poll_for_records(instance, 500)
      end)

    assert log =~ "below the 1000 ms floor"
  end

  defp poll_for_records(instance, timeout_ms) do
    case Scraper.all(instance) do
      [] when timeout_ms > 0 ->
        Process.sleep(10)
        poll_for_records(instance, timeout_ms - 10)

      records ->
        records
    end
  end

  defp write_history(persistence_dir, rrd) do
    binary = rrd |> RRD.save() |> IO.iodata_to_binary()
    File.write!(Path.join(persistence_dir, "history"), binary)
  end

  defp eventually(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_loop(fun, deadline)
  end

  defp eventually_loop(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(100)
        eventually_loop(fun, deadline)
    end
  end

  test "save/1 persists the database so a fresh scraper restores it", %{
    persistence_dir: persistence_dir
  } do
    instance = :scraper_roundtrip

    database =
      RRD.new(@rrd_args)
      |> RRD.insert(1234, [{"vm.memory.total", :last_value, 123, %{}}])
      |> RRD.insert(3000, [{"vm.memory.total", :last_value, 124, %{}}])

    {_pid, ^instance} = start_scraper(instance, persistence_dir, database)

    assert :ok = Scraper.save(instance)

    # File landed at the real path with no temp file left behind.
    assert File.exists?(Path.join(persistence_dir, "history"))
    refute File.exists?(Path.join(persistence_dir, "history.tmp"))

    stop_supervised!(Scraper)

    # A new scraper pointed at the same dir loads an empty database, then
    # recovers the persisted records from disk.
    {_pid, ^instance} = start_scraper(instance, persistence_dir, RRD.new(@rrd_args))

    assert [
             {1234, {"vm.memory.total", :last_value, 123, %{}}},
             {3000, {"vm.memory.total", :last_value, 124, %{}}}
           ] == Scraper.all(instance)
  end

  test "buffers pre-sync scrapes and records them once the clock synchronizes", %{
    persistence_dir: persistence_dir
  } do
    instance = :scraper_unsynced_boot
    FakeClock.set(false)
    on_exit(&FakeClock.clear/0)

    now = System.system_time(:second)

    history = [
      {now - 30, {"vm.memory.total", :last_value, 123, %{}}},
      {now - 20, {"vm.memory.total", :last_value, 124, %{}}}
    ]

    database =
      Enum.reduce(history, RRD.new(@rrd_args), fn {ts, record}, rrd ->
        RRD.insert(rrd, ts, [record])
      end)

    write_history(persistence_dir, database)

    {_pid, ^instance} =
      start_scraper(instance, persistence_dir, RRD.new(@rrd_args), clock: FakeClock)

    MetricsTable.put(instance, [:vm, :memory, :total], :last_value, 125)

    # Let several scrape ticks pass while the clock is unsynchronized.
    Process.sleep(2_500)

    # Nothing recorded into the RRD yet, and the loaded history is intact.
    assert Scraper.all(instance) == history

    flip_time = System.system_time(:second)
    FakeClock.set(true)

    eventually(fn -> length(Scraper.all(instance)) > length(history) end)

    records = Scraper.all(instance)
    assert Enum.take(records, 2) == history

    new_records = records -- history

    # The scrapes parked while unsynchronized were inserted, not dropped:
    # their (step-corrected) timestamps predate the sync flip. The clock in
    # this test never actually steps, so the correction is ~0.
    assert Enum.count(new_records, fn {ts, _} -> ts <= flip_time + 1 end) >= 2

    assert Enum.all?(new_records, fn {ts, record} ->
             ts >= now and record == {"vm.memory.total", :last_value, 125, %{}}
           end)

    timestamps = Enum.map(records, fn {ts, _} -> ts end)
    assert timestamps == Enum.sort(timestamps)
  end

  test "parks nothing when no metrics arrive before the clock syncs", %{
    persistence_dir: persistence_dir
  } do
    instance = :scraper_unsynced_empty
    FakeClock.set(false)
    on_exit(&FakeClock.clear/0)

    {_pid, ^instance} =
      start_scraper(instance, persistence_dir, RRD.new(@rrd_args), clock: FakeClock)

    # Ticks pass with an empty metrics table, then the clock syncs.
    Process.sleep(1_500)
    FakeClock.set(true)
    Process.sleep(1_500)

    assert Scraper.all(instance) == []
  end

  @tag capture_log: true
  test "recovers from future-stamped persisted history with no clock module", %{
    persistence_dir: persistence_dir
  } do
    # Without a :clock module the TimeServer reports synchronized from
    # boot, so the far-below-marks scrape counts as a real backwards step.
    instance = :scraper_future_history
    now = System.system_time(:second)
    ten_years = 10 * 365 * 86_400

    database =
      RRD.new(@rrd_args)
      |> RRD.insert(now + ten_years, [{"vm.memory.total", :last_value, 999, %{}}])

    write_history(persistence_dir, database)

    {_pid, ^instance} = start_scraper(instance, persistence_dir, RRD.new(@rrd_args))

    MetricsTable.put(instance, [:vm, :memory, :total], :last_value, 125)

    eventually(fn ->
      case Scraper.all(instance) do
        [] -> false
        records -> Enum.all?(records, fn {ts, _record} -> ts < now + ten_years end)
      end
    end)

    assert Enum.all?(Scraper.all(instance), fn {ts, _record} -> ts >= now end)
  end
end
