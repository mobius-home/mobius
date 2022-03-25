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
        |> RRD.insert(1234, [
          %{name: "vm.memory.total", type: :last_value, value: 123, tags: %{}, timestamp: 1234}
        ])
        |> RRD.insert(3000, [
          %{name: "vm.memory.total", type: :last_value, value: 124, tags: %{}, timestamp: 3000}
        ])

      in_rrd_binary = RRD.save(in_rrd, serialization_version: 1) |> IO.iodata_to_binary()
      assert RRD.load(RRD.new(@args), in_rrd_binary) == {:ok, expected_rrd}
    end

    test "version 2" do
      rrd =
        RRD.new(@args)
        |> RRD.insert(1234, [
          %{name: "vm.memory.total", type: :last_value, value: 123, tags: %{}, timestamp: 1234}
        ])
        |> RRD.insert(3000, [
          %{name: "vm.memory.total", type: :last_value, value: 124, tags: %{}, timestamp: 3000}
        ])

      rrd_binary = RRD.save(rrd) |> IO.iodata_to_binary()
      assert RRD.load(RRD.new(@args), rrd_binary) == {:ok, rrd}
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
