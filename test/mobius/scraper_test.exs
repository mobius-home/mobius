defmodule Mobius.ScraperTest do
  use ExUnit.Case, async: true

  alias Mobius.{MetricsTable, RRD, Scraper}

  @rrd_args [days: 60, hours: 48, minutes: 120, seconds: 120]

  setup do
    persistence_dir =
      Path.join(System.tmp_dir!(), "mobius_scraper_#{System.unique_integer([:positive])}")

    File.mkdir_p!(persistence_dir)
    on_exit(fn -> File.rm_rf!(persistence_dir) end)

    {:ok, persistence_dir: persistence_dir}
  end

  defp start_scraper(instance, persistence_dir, database, extra_args \\ []) do
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
      ] ++ extra_args

    pid = start_supervised!({Scraper, args})
    {pid, instance}
  end

  test "scrapes at the configured :scrape_interval", %{persistence_dir: persistence_dir} do
    instance = :scraper_fast_interval

    {_pid, ^instance} =
      start_scraper(instance, persistence_dir, RRD.new(@rrd_args), scrape_interval: 50)

    MetricsTable.put(instance, [:scrape, :interval, :test], :last_value, 42)

    # With a 50 ms interval the first scrape lands well within 500 ms; the
    # default 1 s interval would still be waiting for its first tick.
    records = poll_for_records(instance, 500)

    assert [{_ts, {"scrape.interval.test", :last_value, 42, %{}}} | _rest] = records
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
end
