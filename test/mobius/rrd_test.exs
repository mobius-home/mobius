defmodule Mobius.RRDTest do
  use ExUnit.Case, async: true

  alias Mobius.RRD

  @args [days: 60, hours: 48, minutes: 120, seconds: 120]

  test "create a new one" do
    buffer = RRD.new(@args)
    assert RRD.all(buffer) == []
  end

  test "insert a scrape" do
    buffer =
      RRD.new(@args)
      |> RRD.insert(1234, :first)
      |> RRD.insert(1235, :second)

    assert RRD.all(buffer) == [{1234, :first}, {1235, :second}]
  end

  test "query for scrapes in a time range" do
    buffer =
      RRD.new(@args)
      |> RRD.insert(1234, :first)
      |> RRD.insert(3000, :second)

    assert RRD.query(buffer, 1000, 2000) == [{1234, :first}]
    assert RRD.query(buffer, 1000, 3000) == [{1234, :first}, {3000, :second}]
    assert RRD.query(buffer, 2000, 3000) == [{3000, :second}]
    assert RRD.query(buffer, 10, 30) == []

    assert RRD.query(buffer, 1000) == [{1234, :first}, {3000, :second}]
    assert RRD.query(buffer, 3000) == [{3000, :second}]
    assert RRD.query(buffer, 3001) == []
  end

  describe "serialize and decode" do
    test "version 1" do
      in_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, [{[:vm, :memory, :total], :last_value, 123, %{}}])
        |> RRD.insert(3000, [{[:vm, :memory, :total], :last_value, 124, %{}}])

      expected_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[{"vm.memory.total", :last_value, 123, %{}}], %{}})
        |> RRD.insert(3000, {[{"vm.memory.total", :last_value, 124, %{}}], %{}})

      in_rrd_binary = RRD.save(in_rrd, serialization_version: 1) |> IO.iodata_to_binary()
      assert RRD.load(RRD.new(@args), in_rrd_binary) == {:ok, expected_rrd}
    end

    test "version 2 (legacy map-shape records)" do
      v2_in_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, [
          %{name: "vm.memory.total", type: :last_value, value: 123, tags: %{}, timestamp: 1234}
        ])
        |> RRD.insert(3000, [
          %{name: "vm.memory.total", type: :last_value, value: 124, tags: %{}, timestamp: 3000}
        ])

      expected_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[{"vm.memory.total", :last_value, 123, %{}}], %{}})
        |> RRD.insert(3000, {[{"vm.memory.total", :last_value, 124, %{}}], %{}})

      v2_binary = RRD.save(v2_in_rrd, serialization_version: 2) |> IO.iodata_to_binary()
      assert RRD.load(RRD.new(@args), v2_binary) == {:ok, expected_rrd}
    end

    test "version 3 (records and empty histograms)" do
      rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[{"vm.memory.total", :last_value, 123, %{}}], %{}})
        |> RRD.insert(3000, {[{"vm.memory.total", :last_value, 124, %{}}], %{}})

      rrd_binary = RRD.save(rrd) |> IO.iodata_to_binary()
      assert RRD.load(RRD.new(@args), rrd_binary) == {:ok, rrd}
    end

    test "version 3 round-trips records, encoded histograms, and configs" do
      config = %{
        relative_accuracy: 0.1,
        min_indexable_value: 1.0e-9,
        max_indexable_value: 1.0e18,
        on_overflow: :clamp
      }

      configs = %{{"latency.ms", []} => config}
      payload = :erlang.term_to_binary({%{1 => 3, 2 => 17}, %{}, 0})

      rrd =
        RRD.new(@args)
        |> RRD.insert(
          1234,
          {[{"vm.memory.total", :last_value, 123, %{}}], %{{"latency.ms", %{}} => payload}}
        )

      rrd_binary = RRD.save(rrd, histogram_configs: configs) |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), rrd_binary, histogram_configs: configs) == {:ok, rrd}
    end

    test "version 3 loads everything when no current configs are given" do
      configs = %{{"latency.ms", []} => %{relative_accuracy: 0.1}}
      payload = :erlang.term_to_binary({%{1 => 3}, %{}, 0})

      rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[], %{{"latency.ms", %{}} => payload}})

      rrd_binary = RRD.save(rrd, histogram_configs: configs) |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), rrd_binary) == {:ok, rrd}
    end

    @tag capture_log: true
    test "version 3 drops histogram data on config mismatch, keeps records" do
      saved_config = %{
        relative_accuracy: 0.1,
        min_indexable_value: 1.0e-9,
        max_indexable_value: 1.0e18,
        on_overflow: :clamp
      }

      current_config = %{saved_config | relative_accuracy: 0.05}

      payload = :erlang.term_to_binary({%{1 => 3}, %{}, 0})

      rrd =
        RRD.new(@args)
        |> RRD.insert(
          1234,
          {[{"vm.memory.total", :last_value, 123, %{}}], %{{"latency.ms", %{}} => payload}}
        )

      expected_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[{"vm.memory.total", :last_value, 123, %{}}], %{}})

      rrd_binary =
        RRD.save(rrd, histogram_configs: %{{"latency.ms", []} => saved_config})
        |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), rrd_binary,
               histogram_configs: %{{"latency.ms", []} => current_config}
             ) == {:ok, expected_rrd}
    end

    @tag capture_log: true
    test "version 3 drops corrupt histogram payloads, keeps valid ones" do
      good = :erlang.term_to_binary({%{1 => 3}, %{}, 0})
      not_a_term = <<1, 2, 3>>
      wrong_shape = :erlang.term_to_binary([:not, :a, :snapshot])
      negative_count = :erlang.term_to_binary({%{1 => -3}, %{}, 0})

      rrd =
        RRD.new(@args)
        |> RRD.insert(
          1234,
          {[],
           %{
             {"latency.ms", %{}} => good,
             {"broken.one.ms", %{}} => not_a_term,
             {"broken.two.ms", %{}} => wrong_shape,
             {"broken.three.ms", %{}} => negative_count
           }}
        )

      expected_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[], %{{"latency.ms", %{}} => good}})

      rrd_binary = RRD.save(rrd) |> IO.iodata_to_binary()

      # Corrupt payloads are dropped even when no current configs are given
      # — they would otherwise raise at query time, not load time.
      assert RRD.load(RRD.new(@args), rrd_binary) == {:ok, expected_rrd}
    end

    @tag capture_log: true
    test "version 3 drops histogram data when the metric is no longer histogram-enabled" do
      configs = %{{"latency.ms", []} => %{relative_accuracy: 0.1}}
      payload = :erlang.term_to_binary({%{1 => 3}, %{}, 0})

      rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[], %{{"latency.ms", %{}} => payload}})

      expected_rrd = RRD.new(@args) |> RRD.insert(1234, {[], %{}})

      rrd_binary = RRD.save(rrd, histogram_configs: configs) |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), rrd_binary, histogram_configs: %{}) == {:ok, expected_rrd}
    end

    test "compression_level changes the payload size but round-trips either way" do
      # redundant data so compression has something to work with
      rrd =
        Enum.reduce(1..120, RRD.new(@args), fn ts, acc ->
          RRD.insert(acc, ts, [{"vm.memory.total", :last_value, rem(ts, 10), %{}}])
        end)

      uncompressed = RRD.save(rrd, compression_level: 0) |> IO.iodata_to_binary()
      compressed = RRD.save(rrd, compression_level: 9) |> IO.iodata_to_binary()

      assert byte_size(compressed) < byte_size(uncompressed)
      assert RRD.load(RRD.new(@args), uncompressed) == {:ok, rrd}
      assert RRD.load(RRD.new(@args), compressed) == {:ok, rrd}
    end

    @tag capture_log: true
    test "load discards persisted entries with future timestamps" do
      # A device that boots with a wrong-ahead clock (dead RTC battery)
      # persists future-stamped entries. Once NTP steps the clock back,
      # those entries rebuild the high-water marks past the present at
      # load, so every new insert is silently dropped until wall-clock
      # catches up — surviving reboots because the RRD is persisted.
      now = 1_700_000_000
      ten_years = 10 * 365 * 86_400
      snapshot = {[{"vm.memory.total", :last_value, 123, %{}}], %{}}

      saved_binary =
        RRD.new(@args)
        |> RRD.insert(now + ten_years, snapshot)
        |> RRD.save()
        |> IO.iodata_to_binary()

      {:ok, loaded} = RRD.load(RRD.new(@args), saved_binary, now: now)

      rrd = RRD.insert(loaded, now, snapshot)

      assert RRD.all(rrd) == [{now, snapshot}]
    end

    test "load keeps entries within the future tolerance" do
      now = 1_700_000_000
      slightly_ahead = now + 60
      snapshot = {[{"vm.memory.total", :last_value, 123, %{}}], %{}}

      saved_binary =
        RRD.new(@args)
        |> RRD.insert(slightly_ahead, snapshot)
        |> RRD.save()
        |> IO.iodata_to_binary()

      assert {:ok, loaded} = RRD.load(RRD.new(@args), saved_binary, now: now)
      assert RRD.all(loaded) == [{slightly_ahead, snapshot}]
    end

    @tag capture_log: true
    test "load defaults :now to the system clock" do
      ten_years = 10 * 365 * 86_400
      snapshot = {[{"vm.memory.total", :last_value, 123, %{}}], %{}}

      saved_binary =
        RRD.new(@args)
        |> RRD.insert(System.system_time(:second) + ten_years, snapshot)
        |> RRD.save()
        |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), saved_binary) == {:ok, RRD.new(@args)}
    end

    @tag capture_log: true
    test "load discards future-stamped entries from v1 and v2 files too" do
      now = 1_700_000_000
      ten_years = 10 * 365 * 86_400

      v1_binary =
        RRD.new(@args)
        |> RRD.insert(now + ten_years, [{[:vm, :memory, :total], :last_value, 123, %{}}])
        |> RRD.save(serialization_version: 1)
        |> IO.iodata_to_binary()

      v2_binary =
        RRD.new(@args)
        |> RRD.insert(now + ten_years, [
          %{name: "vm.memory.total", type: :last_value, value: 123, tags: %{}, timestamp: now}
        ])
        |> RRD.save(serialization_version: 2)
        |> IO.iodata_to_binary()

      assert RRD.load(RRD.new(@args), v1_binary, now: now) == {:ok, RRD.new(@args)}
      assert RRD.load(RRD.new(@args), v2_binary, now: now) == {:ok, RRD.new(@args)}
    end

    test "loads uncompressed v2 payloads (backwards compat)" do
      v2_in_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, [
          %{name: "vm.memory.total", type: :last_value, value: 123, tags: %{}, timestamp: 1234}
        ])
        |> RRD.insert(3000, [
          %{name: "vm.memory.total", type: :last_value, value: 124, tags: %{}, timestamp: 3000}
        ])

      expected_rrd =
        RRD.new(@args)
        |> RRD.insert(1234, {[{"vm.memory.total", :last_value, 123, %{}}], %{}})
        |> RRD.insert(3000, {[{"vm.memory.total", :last_value, 124, %{}}], %{}})

      uncompressed_binary =
        IO.iodata_to_binary([2, :erlang.term_to_binary(RRD.all(v2_in_rrd))])

      assert RRD.load(RRD.new(@args), uncompressed_binary) == {:ok, expected_rrd}
    end
  end

  test "fails to load corrupt binaries" do
    empty_tlb = RRD.new(@args)

    bad_version = <<100, 2, 3, 4>>

    assert RRD.load(empty_tlb, bad_version) ==
             {:error, Mobius.DataLoadError.exception(reason: :unsupported_version)}

    bad_term = <<1, 2, 3, 4, 5>>

    assert RRD.load(empty_tlb, bad_term) ==
             {:error, Mobius.DataLoadError.exception(reason: :corrupt)}

    unexpected_term = <<1>> <> :erlang.term_to_binary(:not_a_list)

    assert RRD.load(empty_tlb, unexpected_term) ==
             {:error, Mobius.DataLoadError.exception(reason: :corrupt)}

    unexpected_term2 = <<1>> <> :erlang.term_to_binary([:not_a_tuple])

    assert RRD.load(empty_tlb, unexpected_term2) ==
             {:error, Mobius.DataLoadError.exception(reason: :corrupt)}

    unexpected_term3 = <<1>> <> :erlang.term_to_binary([{:not_a_timestamp, :value}])

    assert RRD.load(empty_tlb, unexpected_term3) ==
             {:error, Mobius.DataLoadError.exception(reason: :corrupt)}
  end

  test "rolled_off? flips once the day archive fills to capacity" do
    rrd = RRD.new(days: 2, hours: 2, minutes: 2, seconds: 2)
    refute RRD.rolled_off?(rrd)

    rrd = RRD.insert(rrd, 0, :first_day)
    refute RRD.rolled_off?(rrd)

    rrd = RRD.insert(rrd, 86_400, :second_day)
    assert RRD.rolled_off?(rrd)
  end

  test "fill up the all buffers" do
    now = 60 * 86400

    # Insert 60 days of records
    buffer =
      Enum.reduce(
        0..(now - 1),
        RRD.new(@args),
        &RRD.insert(&2, &1, &1)
      )

    # Last 2 seconds
    assert Enum.count(RRD.query(buffer, now - 2)) == 2

    # Last 2 minutes (all 120 second resolution samples)
    assert Enum.count(RRD.query(buffer, now - 2 * 60)) == 120

    # Last 3 minutes (3 minute samples and all 120 seconds of samples)
    assert Enum.count(RRD.query(buffer, now - 3 * 60)) == 123

    # Last 2 hours (2 hour samples, 118 minute samples, all 120 second samples)
    assert Enum.count(RRD.query(buffer, now - 2 * 3600)) == 2 + 118 + 120

    # Last 2 days (2 day samples, 46 hour samples, all 120 minute samples and all 120 second samples)
    assert Enum.count(RRD.query(buffer, now - 2 * 86400)) == 2 + 46 + 120 + 120

    # Last 3 days (3 day samples, 48 hour samples, all 120 minute samples and all 120 second samples)
    assert Enum.count(RRD.query(buffer, now - 3 * 86400)) == 3 + 48 + 120 + 120

    # Last 60 days
    assert Enum.count(RRD.query(buffer, 0)) == 60 + 48 + 120 + 120
  end
end
