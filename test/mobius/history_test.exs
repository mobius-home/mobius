defmodule Mobius.HistoryTest do
  use ExUnit.Case, async: true

  alias Mobius.History

  @args [day_count: 60, hour_count: 48, minute_count: 120, second_count: 120]

  test "create a new one" do
    buffer = History.new(@args)
    assert History.all(buffer) == []
  end

  test "insert a scrape" do
    buffer =
      History.new(@args)
      |> History.insert(1234, :first)
      |> History.insert(1235, :second)

    assert History.all(buffer) == [{1234, :first}, {1235, :second}]
  end

  test "query for scrapes in a time range" do
    buffer =
      History.new(@args)
      |> History.insert(1234, :first)
      |> History.insert(3000, :second)

    assert History.query(buffer, 1000, 2000) == [{1234, :first}]
    assert History.query(buffer, 1000, 3000) == [{1234, :first}, {3000, :second}]
    assert History.query(buffer, 2000, 3000) == [{3000, :second}]
    assert History.query(buffer, 10, 30) == []

    assert History.query(buffer, 1000) == [{1234, :first}, {3000, :second}]
    assert History.query(buffer, 3000) == [{3000, :second}]
    assert History.query(buffer, 3001) == []
  end

  test "turn into a binary" do
    buffer =
      History.new(@args)
      |> History.insert(1234, :first)
      |> History.insert(3000, :second)

    buffer_bin = History.save(buffer) |> IO.iodata_to_binary()
    assert History.load(History.new(@args), buffer_bin) == {:ok, buffer}
  end

  test "fails to load corrupt binaries" do
    empty_tlb = History.new(@args)

    bad_version = <<100, 2, 3, 4>>
    assert History.load(empty_tlb, bad_version) == {:error, :unsupported_version}

    bad_term = <<1, 2, 3, 4, 5>>
    assert History.load(empty_tlb, bad_term) == {:error, :corrupt}

    unexpected_term = <<1>> <> :erlang.term_to_binary(:not_a_list)
    assert History.load(empty_tlb, unexpected_term) == {:error, :corrupt}

    unexpected_term2 = <<1>> <> :erlang.term_to_binary([:not_a_tuple])
    assert History.load(empty_tlb, unexpected_term2) == {:error, :corrupt}

    unexpected_term3 = <<1>> <> :erlang.term_to_binary([{:not_a_timestamp, :value}])
    assert History.load(empty_tlb, unexpected_term3) == {:error, :corrupt}
  end

  test "fill up the all buffers" do
    now = 60 * 86400

    # Insert 60 days of records
    buffer =
      Enum.reduce(
        0..(now - 1),
        History.new(@args),
        &History.insert(&2, &1, &1)
      )

    # Last 2 seconds
    assert Enum.count(History.query(buffer, now - 2)) == 2

    # Last 2 minutes (all 120 second resolution samples)
    assert Enum.count(History.query(buffer, now - 2 * 60)) == 120

    # Last 3 minutes (3 minute samples and all 120 seconds of samples)
    assert Enum.count(History.query(buffer, now - 3 * 60)) == 123

    # Last 2 hours (2 hour samples, 118 minute samples, all 120 second samples)
    assert Enum.count(History.query(buffer, now - 2 * 3600)) == 2 + 118 + 120

    # Last 2 days (2 day samples, 46 hour samples, all 120 minute samples and all 120 second samples)
    assert Enum.count(History.query(buffer, now - 2 * 86400)) == 2 + 46 + 120 + 120

    # Last 3 days (3 day samples, 48 hour samples, all 120 minute samples and all 120 second samples)
    assert Enum.count(History.query(buffer, now - 3 * 86400)) == 3 + 48 + 120 + 120

    # Last 60 days
    assert Enum.count(History.query(buffer, 0)) == 60 + 48 + 120 + 120
  end
end
