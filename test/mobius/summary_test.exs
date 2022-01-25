defmodule Mobius.SummaryTest do
  use ExUnit.Case, async: true

  alias Mobius.Summary

  test "create new summary data from a measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      min: 100,
      max: 100
    }

    assert expected_summary_data == Summary.new(100)
  end

  test "update one with a new measurement" do
    expected_summary_data = %{
      reports: 1,
      accumulated: 100,
      min: 100,
      max: 100
    }

    assert expected_summary_data == Summary.new(100)
  end

  test "calculate summary from summary data" do
    expected_summary = %{min: 100, max: 400, average: 250}

    summary_data =
      100
      |> Summary.new()
      |> Summary.update(400)

    assert expected_summary == Summary.calculate(summary_data)
  end
end
