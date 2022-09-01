defmodule Mobius.SummaryTest do
  use ExUnit.Case, async: true

  alias Mobius.Summary

  test "create new summary data from a measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      accumulated_sqrd: 10000,
      min: 100,
      max: 100,
      t_digest: TDigest.new() |> TDigest.update(100)
    }

    assert expected_summary_data == Summary.new(100)
  end

  test "update one with a new measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      accumulated_sqrd: 10000,
      min: 100,
      max: 100,
      t_digest: TDigest.new() |> TDigest.update(100)
    }

    assert expected_summary_data == Summary.new(100)
  end

  test "calculate summary from summary data" do
    expected_summary = %{
      min: 10,
      max: 750,
      average: 382,
      std_dev: 301.1016808691413,
      p50: 350,
      p75: 750,
      p95: 750,
      p99: 750
    }

    [first_value | tail_values] = [10, 10, 100, 200, 300, 400, 600, 700, 750, 750]

    summary_data =
      for metric_value <- tail_values, reduce: Summary.new(first_value) do
        acc -> Summary.update(acc, metric_value)
      end

    assert expected_summary == Summary.calculate(summary_data)
  end
end
