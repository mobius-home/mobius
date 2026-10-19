defmodule Mobius.SummaryTest do
  use ExUnit.Case, async: true

  alias Mobius.Summary

  test "create new summary data from a measurement" do
    assert %{reports: 1, shift: 100, mean: +0.0, m2: +0.0} == Summary.new(100)
  end

  test "update summary data with a new measurement" do
    assert %{reports: 2, shift: 100, mean: 150.0, m2: 45_000.0} ==
             100 |> Summary.new() |> Summary.update(400)
  end

  test "calculate summary from summary data" do
    expected_summary = %{average: 250.0, std_dev: 212.13203435596427, reports: 2}

    summary_data =
      100
      |> Summary.new()
      |> Summary.update(400)

    assert expected_summary == Summary.calculate(summary_data)
  end

  # `Summary.t()` types `:std_dev` as `float()`, so a single-report summary
  # must produce `0.0` rather than the integer `0`.
  test "calculate returns a float std_dev for a single report" do
    summary = 100 |> Summary.new() |> Summary.calculate()

    assert is_float(summary.std_dev)
    assert summary.std_dev == 0.0
  end

  test "calculate exposes the report count as the subgroup size" do
    summary_data =
      100
      |> Summary.new()
      |> Summary.update(400)
      |> Summary.update(250)

    assert %{reports: 3} = Summary.calculate(summary_data)
  end

  # https://github.com/mobius-home/mobius/issues/152: `system_time`-shaped
  # measurements (~10^12, a step of 1 apart). The old sum-of-squares variance
  # cancelled to a negative number here and :math.sqrt/1 raised.
  test "calculate is accurate for large, closely spaced measurements" do
    summary_data =
      1_788_878_897_448
      |> Summary.new()
      |> Summary.update(1_788_878_897_449)
      |> Summary.update(1_788_878_897_450)

    assert %{average: 1_788_878_897_449.0, std_dev: 1.0, reports: 3} ==
             Summary.calculate(summary_data)
  end

  test "calculate is accurate for large, closely spaced float measurements" do
    summary_data =
      Enum.reduce(1..99, Summary.new(1.0e12), &Summary.update(&2, 1.0e12 + &1 * 0.5))

    # 0, 0.5, ..., 49.5 offset from 10^12: sample std dev of 0..99 halved
    expected = :math.sqrt(100 * 101 / 12) / 2

    assert %{reports: 100, std_dev: std_dev} = Summary.calculate(summary_data)
    assert_in_delta std_dev, expected, 1.0e-6
  end

  describe "subtract/2" do
    test "yields the summary of only the reports between two snapshots" do
      base = 1_788_878_897_448
      earlier = Enum.reduce(1..9, Summary.new(base), &Summary.update(&2, base + &1))
      later = Enum.reduce([7, 9], earlier, &Summary.update(&2, base + &1))

      assert %{average: average, std_dev: std_dev, reports: 2} =
               later |> Summary.subtract(earlier) |> Summary.calculate()

      assert_in_delta average, base + 8, 1.0e-3
      assert_in_delta std_dev, :math.sqrt(2), 1.0e-9
    end

    test "matches accumulating the window on its own" do
      earlier = Enum.reduce([3, 8, 1], Summary.new(5), &Summary.update(&2, &1))
      later = Enum.reduce([10, 20, 60], earlier, &Summary.update(&2, &1))
      window = Enum.reduce([20, 60], Summary.new(10), &Summary.update(&2, &1))

      assert %{average: avg, std_dev: std_dev, reports: 3} =
               later |> Summary.subtract(earlier) |> Summary.calculate()

      expected = Summary.calculate(window)
      assert_in_delta avg, expected.average, 1.0e-9
      assert_in_delta std_dev, expected.std_dev, 1.0e-9
    end

    test "accepts a legacy snapshot as the earlier side" do
      legacy = %{reports: 2, accumulated: 500, accumulated_sqrd: 170_000}
      later = legacy |> Summary.update(10) |> Summary.update(20)

      assert %{average: 15.0, reports: 2} =
               later |> Summary.subtract(legacy) |> Summary.calculate()
    end
  end

  # Persisted summary data from older versions of Mobius stores the running
  # sum and sum of squares, and older still also carried `:min` and `:max`.
  # Loading that data must continue to work.
  describe "loading legacy summary data" do
    test "calculate converts legacy sums and ignores min/max keys" do
      legacy_data = %{
        reports: 2,
        accumulated: 500,
        accumulated_sqrd: 170_000,
        min: 100,
        max: 400
      }

      assert %{average: 250.0, std_dev: 212.13203435596427, reports: 2} ==
               Summary.calculate(legacy_data)
    end

    test "update converts legacy data and keeps producing correct results" do
      legacy_data = %{
        reports: 1,
        accumulated: 100,
        accumulated_sqrd: 10_000,
        min: 100,
        max: 100
      }

      updated = Summary.update(legacy_data, 400)

      assert updated == %{reports: 2, shift: 0, mean: 250.0, m2: 45_000.0}

      assert %{average: 250.0, std_dev: 212.13203435596427, reports: 2} ==
               Summary.calculate(updated)
    end
  end
end
