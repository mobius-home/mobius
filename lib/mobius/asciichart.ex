defmodule Mobius.Asciichart do
  @moduledoc false

  # ASCII chart generation.

  # This module was taking from [sndnv's elixir asciichart package](https://github.com/sndnv/asciichart)
  # and slightly modified to meet the needs of this project.

  # Ported to Elixir from [https://github.com/kroitor/asciichart](https://github.com/kroitor/asciichart)

  @doc ~S"""
  Generates a chart for the specified list of numbers.

  Optionally, the following settings can be provided:
    * :offset - the number of characters to set as the chart's offset (left)
    * :height - adjusts the height of the chart
    * :padding - one or more characters to use for the label's padding (left)

  ## Examples
      iex> Asciichart.plot([1, 2, 3, 3, 2, 1])
      {:ok, "3.00 ┤ ╭─╮   \n2.00 ┤╭╯ ╰╮  \n1.00 ┼╯   ╰  \n          "}

      # should render as

      3.00 ┤ ╭─╮
      2.00 ┤╭╯ ╰╮
      1.00 ┼╯   ╰

      iex> Asciichart.plot([1, 2, 6, 6, 2, 1], height: 2)
      {:ok, "6.00 ┼       \n3.50 ┤ ╭─╮   \n1.00 ┼─╯ ╰─  \n          "}

      # should render as

      6.00 ┼
      3.50 ┤ ╭─╮
      1.00 ┼─╯ ╰─

      iex> Asciichart.plot([1, 2, 5, 5, 4, 3, 2, 100, 0], height: 3, offset: 10, padding: "__")
      {:ok, "    100.00    ┼      ╭╮  \n    _50.00    ┤      ││  \n    __0.00    ┼──────╯╰  \n                    "}

      # should render as

          100.00    ┼      ╭╮
          _50.00    ┤      ││
          __0.00    ┼──────╯╰


      # Rendering of empty charts is not supported

      iex> Asciichart.plot([])
      {:error, "No data"}
  """
  def plot(series, cfg \\ %{}) do
    case series do
      [] ->
        {:error, "No data"}

      [_ | _] ->
        minimum = Enum.min(series)
        maximum = Enum.max(series)

        interval = abs(maximum - minimum)
        offset = cfg[:offset] || 3
        height = if cfg[:height], do: cfg[:height] - 1, else: interval
        padding = cfg[:padding] || " "
        ratio = if interval == 0, do: 1, else: height / interval

        min2 = safe_floor(minimum * ratio)
        max2 = safe_ceil(maximum * ratio)

        intmin2 = trunc(min2)
        intmax2 = trunc(max2)

        rows = abs(intmax2 - intmin2)
        width = length(series) + offset

        # empty space
        result =
          0..(rows + 1)
          |> Enum.map(fn x ->
            {x, 0..width |> Enum.map(fn y -> {y, " "} end) |> Enum.into(%{})}
          end)
          |> Enum.into(%{})

        max_label_size =
          (maximum / 1)
          |> Float.round(2)
          |> :erlang.float_to_binary(decimals: 2)
          |> String.length()

        min_label_size =
          (minimum / 1)
          |> Float.round(2)
          |> :erlang.float_to_binary(decimals: 2)
          |> String.length()

        label_size = max(min_label_size, max_label_size)

        # axis and labels
        result =
          intmin2..intmax2
          |> Enum.reduce(result, fn y, map ->
            label =
              (maximum - (y - intmin2) * interval / (rows + 1))
              |> Float.round(2)
              |> :erlang.float_to_binary(decimals: 2)
              |> String.pad_leading(label_size, padding)

            updated_map = put_in(map[y - intmin2][max(offset - String.length(label), 0)], label)
            put_in(updated_map[y - intmin2][offset - 1], if(y == 0, do: "┼", else: "┤"))
          end)

        # first value
        y0 = trunc(Enum.at(series, 0) * ratio - min2)
        result = put_in(result[rows - y0][offset - 1], "┼")

        # plot the line
        result =
          0..(length(series) - 2)
          |> Enum.reduce(result, fn x, map ->
            y0 = trunc(Enum.at(series, x + 0) * ratio - intmin2)
            y1 = trunc(Enum.at(series, x + 1) * ratio - intmin2)

            if y0 == y1 do
              put_in(map[rows - y0][x + offset], "─")
            else
              updated_map =
                put_in(
                  map[rows - y1][x + offset],
                  if(y0 > y1, do: "╰", else: "╭")
                )

              updated_map =
                put_in(
                  updated_map[rows - y0][x + offset],
                  if(y0 > y1, do: "╮", else: "╯")
                )

              (min(y0, y1) + 1)..max(y0, y1)
              |> Enum.drop(-1)
              |> Enum.reduce(updated_map, fn y, map ->
                put_in(map[rows - y][x + offset], "│")
              end)
            end
          end)

        # ensures cell order, regardless of map sizes
        result =
          result
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {_, x} ->
            x
            |> Enum.sort_by(fn {k, _} -> k end)
            |> Enum.map(fn {_, y} -> y end)
            |> Enum.join()
          end)
          |> Enum.join("\n")

        {:ok, result}
    end
  end

  defp safe_floor(n) when is_integer(n) do
    n
  end

  defp safe_floor(n) when is_float(n) do
    Float.floor(n)
  end

  defp safe_ceil(n) when is_integer(n) do
    n
  end

  defp safe_ceil(n) when is_float(n) do
    Float.ceil(n)
  end
end
