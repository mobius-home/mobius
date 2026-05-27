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
    expected_summary = %{average: 250.0, std_dev: 212.13203435596427}

    summary_data =
      100
      |> Summary.new()
      |> Summary.update(400)

    assert expected_summary == Summary.calculate(summary_data)
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

      assert %{average: 250.0, std_dev: 212.13203435596427} ==
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

      assert %{average: 250.0, std_dev: 212.13203435596427} ==
               Summary.calculate(updated)
    end
  end
end
