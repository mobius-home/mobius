defmodule Mobius.SummaryTest do
  use ExUnit.Case, async: true

  alias Mobius.Summary

  test "create new summary data from a measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      accumulated_sqrd: 10000
    }

    assert expected_summary_data == Summary.new(100)
  end

  test "update one with a new measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      accumulated_sqrd: 10000
    }

    assert expected_summary_data == Summary.new(100)
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

  test "calculate is exact for large, closely spaced integer measurements" do
    summary_data =
      1_788_878_897_448
      |> Summary.new()
      |> Summary.update(1_788_878_897_449)
      |> Summary.update(1_788_878_897_450)

    assert %{average: 1_788_878_897_449.0, std_dev: 1.0, reports: 3} ==
             Summary.calculate(summary_data)
  end

  test "calculate does not report rounding noise as spread" do
    base = 1_788_878_897_448
    values = [0, 1000, 0, 1000] |> Enum.map(&(base + &1))
    [first | rest] = values
    summary_data = Enum.reduce(rest, Summary.new(first), &Summary.update(&2, &1))

    assert %{std_dev: std_dev} = Summary.calculate(summary_data)
    assert std_dev == :math.sqrt(1_000_000 / 3)
  end

  test "calculate is exact for windows produced by subtracting snapshots" do
    base = 1_788_878_897_448
    earlier = Enum.reduce(1..9, Summary.new(base), &Summary.update(&2, base + &1))
    later = Enum.reduce([7, 9], earlier, &Summary.update(&2, base + &1))

    window = %{
      accumulated: later.accumulated - earlier.accumulated,
      accumulated_sqrd: later.accumulated_sqrd - earlier.accumulated_sqrd,
      reports: later.reports - earlier.reports
    }

    assert %{average: average, std_dev: std_dev, reports: 2} = Summary.calculate(window)
    assert average == base + 8.0
    assert std_dev == :math.sqrt(2)
  end

  # The naive sum-of-squares variance can go negative through catastrophic
  # cancellation when large float values flow through, which would make
  # :math.sqrt/1 raise. calculate/1 must clamp the operand at 0. The data
  # below is crafted so the unclamped operand is negative.
  test "calculate clamps a negative naive variance operand instead of raising" do
    # Two close, large float values. Their true spread is tiny, but the
    # stored sum-of-squares loses enough precision that the naive variance
    # operand comes out negative.
    a = :math.pow(10, 12) + 5.0
    b = :math.pow(10, 12) + 6.0
    sum = a + b
    accumulated_sqrd = a * a + b * b
    n = 2

    data = %{accumulated: sum, accumulated_sqrd: accumulated_sqrd, reports: n}

    # Guard: the unclamped formula must actually go negative for this case,
    # so :math.sqrt/1 would raise without the clamp. Compute the operand from
    # the stored map so the analyzer can't fold it to a negative literal.
    %{accumulated: s, accumulated_sqrd: sq, reports: r} = data
    naive_operand = (sq - s * s / r) / (r - 1)
    assert naive_operand < 0
    assert_raise ArithmeticError, fn -> :math.sqrt(naive_operand) end

    assert %{std_dev: +0.0} = Summary.calculate(data)
  end

  # Persisted summary data from older versions of Mobius carried `:min` and
  # `:max` keys. Loading that data must continue to work — the unused keys
  # should be silently ignored.
  describe "loading legacy summary data with :min/:max" do
    test "calculate ignores legacy min/max keys" do
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

    test "update drops legacy min/max keys and keeps producing correct results" do
      legacy_data = %{
        reports: 1,
        accumulated: 100,
        accumulated_sqrd: 10_000,
        min: 100,
        max: 100
      }

      updated = Summary.update(legacy_data, 400)

      assert updated == %{reports: 2, accumulated: 500, accumulated_sqrd: 170_000}

      assert %{average: 250.0, std_dev: 212.13203435596427, reports: 2} ==
               Summary.calculate(updated)
    end
  end
end
