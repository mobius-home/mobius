defmodule Mobius.PlotTest do
  use ExUnit.Case, async: true

  alias Mobius.Plot

  defp points(values) do
    for {v, i} <- Enum.with_index(values), do: %{timestamp: 1000 + i, value: v}
  end

  defp lines(string), do: String.split(string, "\n", trim: true)

  describe "line/2" do
    test "returns an error for no data" do
      assert {:error, "No data"} = Plot.line([], [])
    end

    test "renders axes, a curve, and a relative time x-axis" do
      assert {:ok, chart} = Plot.line(points([1, 2, 3, 2, 1]), [])

      # Box-drawing y-axis on every data row, and the x-axis corner below.
      assert String.contains?(chart, "┤")
      assert String.contains?(chart, "└")
      # The braille curve uses characters from the U+2800 block.
      assert chart =~ ~r/[\x{2800}-\x{28FF}]/u
      # Ends with a single newline.
      assert String.ends_with?(chart, "\n")
      refute String.ends_with?(chart, "\n\n")
    end

    test "never leaves trailing whitespace on a line" do
      {:ok, chart} = Plot.line(points([1, 5, 2, 8, 3, 1, 6]), [])

      for line <- lines(chart) do
        refute String.ends_with?(line, " "), "trailing whitespace on: #{inspect(line)}"
      end
    end

    test "marks the zero crossing with ┼ when the range spans zero" do
      {:ok, chart} = Plot.line(points([-3, -1, 0, 2, 4]), [])
      assert String.contains?(chart, "┼")
    end

    test "uses ┤ throughout when the range does not span zero" do
      {:ok, chart} = Plot.line(points([1, 2, 3]), [])
      refute String.contains?(chart, "┼")
    end

    test "honours the requested height (one label row per character row)" do
      {:ok, chart} = Plot.line(points([1, 2, 3, 4]), height: 3)
      # 3 data rows + 1 tick row + 1 label row.
      assert length(lines(chart)) == 5
    end

    test "labels the top and bottom rows with the data extremes" do
      {:ok, chart} = Plot.line(points([10, 20, 30]), height: 3)
      [first | _] = lines(chart)
      assert String.contains?(first, "30")
    end
  end

  describe "histogram/2" do
    test "returns an error for no data" do
      assert {:error, "No data"} = Plot.histogram([], [])
    end

    test "renders one bar per bin, scaled to the largest count" do
      bins = [%{value: 1.0, count: 10}, %{value: 2.0, count: 5}, %{value: 3.0, count: 1}]
      assert {:ok, chart} = Plot.histogram(bins, [])

      rows = lines(chart)
      assert length(rows) == 3

      # The bar of the largest bin is wider than the smaller ones.
      [big, mid, small] =
        Enum.map(rows, fn row -> row |> String.graphemes() |> Enum.count(&(&1 == "█")) end)

      assert big > mid
      assert mid >= small

      # Each row carries the bin value, the axis, and the count.
      assert Enum.all?(rows, &String.contains?(&1, "│"))
      assert List.first(rows) |> String.contains?("10")
    end
  end
end
