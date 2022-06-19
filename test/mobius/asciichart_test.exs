defmodule Mobius.AsciichartTest do
  use ExUnit.Case, async: false

  alias Mobius.Asciichart

  doctest Asciichart

  describe "plot/2" do
    test "Can generate a chart with nonvarying values" do
      # Ensure that we don't blow up when creating a chart with a single row of unvarying values
      assert {:ok, plot} = Asciichart.plot([1, 1, 1, 1])
      assert "1.00 ┼───\n" == plot
    end

    test "symmetry around 0" do
      expected =
        [
          " 20.00 ┤ ╭╮     ",
          " 16.00 ┤ ││     ",
          " 12.00 ┤ ││     ",
          "  8.00 ┤╭╯╰╮    ",
          "  4.00 ┤│  │    ",
          "  0.00 ┼╯┄┄╰╮┄┄╭",
          " -4.00 ┤    │  │",
          " -8.00 ┤    ╰╮╭╯",
          "-12.00 ┤     ││ ",
          "-16.00 ┤     ││ ",
          "-20.00 ┤     ╰╯ ",
          ""
        ]
        |> Enum.join("\n")

      {:ok, plot} = Asciichart.plot([0, 10, 20, 10, 0, -10, -20, -10, 0], height: 10)

      assert expected == plot
    end

    test "use cross for axis place the graph originates from" do
      expected =
        [
          " 20.00 ┤╭╮     ",
          " 16.00 ┤││     ",
          " 12.00 ┤││     ",
          "  8.00 ┼╯╰╮    ",
          "  4.00 ┤  │    ",
          "  0.00 ┼┄┄╰╮┄┄╭",
          " -4.00 ┤   │  │",
          " -8.00 ┤   ╰╮╭╯",
          "-12.00 ┤    ││ ",
          "-16.00 ┤    ││ ",
          "-20.00 ┤    ╰╯ ",
          ""
        ]
        |> Enum.join("\n")

      {:ok, plot} = Asciichart.plot([10, 20, 10, 0, -10, -20, -10, 0], height: 10)

      assert expected == plot
    end
  end

  describe "x axis" do
    test "works" do
      expected =
        [
          " 20.00 ┤ ╭╮      ╭╮     ",
          " 16.00 ┤ ││      ││     ",
          " 12.00 ┤ ││      ││     ",
          "  8.00 ┤╭╯╰╮    ╭╯╰╮    ",
          "  4.00 ┤│  │    │  │    ",
          "  0.00 ┼╯┄┄╰╮┄┄╭╯┄┄╰╮┄┄╭",
          " -4.00 ┤    │  │    │  │",
          " -8.00 ┤    ╰╮╭╯    ╰╮╭╯",
          "-12.00 ┤     ││      ││ ",
          "-16.00 ┤     ││      ││ ",
          "-20.00 ┤     ╰╯      ╰╯ ",
          "       └┬────┬────┬────┬",
          "        0    5   10   15",
          ""
        ]
        |> Enum.join("\n")

      {:ok, plot} =
        Asciichart.plot_with_x_axis(
          [0, 10, 20, 10, 0, -10, -20, -10, 0, 10, 20, 10, 0, -10, -20, -10, 0],
          nil,
          height: 10
        )

      assert expected == plot
    end

    test "explicit x series" do
      expected =
        [
          " 20.00 ┤ ╭╮      ╭╮     ",
          " 16.00 ┤ ││      ││     ",
          " 12.00 ┤ ││      ││     ",
          "  8.00 ┤╭╯╰╮    ╭╯╰╮    ",
          "  4.00 ┤│  │    │  │    ",
          "  0.00 ┼╯┄┄╰╮┄┄╭╯┄┄╰╮┄┄╭",
          " -4.00 ┤    │  │    │  │",
          " -8.00 ┤    ╰╮╭╯    ╰╮╭╯",
          "-12.00 ┤     ││      ││ ",
          "-16.00 ┤     ││      ││ ",
          "-20.00 ┤     ╰╯      ╰╯ ",
          "       └┬─────┬─────┬───",
          "       -16   -10   -4   ",
          ""
        ]
        |> Enum.join("\n")

      {:ok, plot} =
        Asciichart.plot_with_x_axis(
          [0, 10, 20, 10, 0, -10, -20, -10, 0, 10, 20, 10, 0, -10, -20, -10, 0],
          [-16, -15, -14, -13, -12, -11, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0],
          height: 10
        )

      assert expected == plot
    end

    test "wide x values" do
      expected =
        [
          " 20.00 ┤ ╭╮      ╭╮     ",
          " 16.00 ┤ ││      ││     ",
          " 12.00 ┤ ││      ││     ",
          "  8.00 ┤╭╯╰╮    ╭╯╰╮    ",
          "  4.00 ┤│  │    │  │    ",
          "  0.00 ┼╯┄┄╰╮┄┄╭╯┄┄╰╮┄┄╭",
          " -4.00 ┤    │  │    │  │",
          " -8.00 ┤    ╰╮╭╯    ╰╮╭╯",
          "-12.00 ┤     ││      ││ ",
          "-16.00 ┤     ││      ││ ",
          "-20.00 ┤     ╰╯      ╰╯ ",
          "       └┬─────────────┬─",
          "      2000          2015",
          ""
        ]
        |> Enum.join("\n")

      {:ok, plot} =
        Asciichart.plot_with_x_axis(
          [0, 10, 20, 10, 0, -10, -20, -10, 0, 10, 20, 10, 0, -10, -20, -10, 0],
          2000..2017 |> Enum.to_list(),
          height: 10
        )

      assert expected == plot
    end
  end
end
