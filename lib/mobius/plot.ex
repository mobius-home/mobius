defmodule Mobius.Plot do
  @moduledoc false

  # Terminal rendering for the `Mobius` helpers. Both renderers return strings;
  # the caller does the IO.
  #
  #   * `line/2`      - a time series as a braille curve (2x4 dots/cell) inside
  #                     box-drawing axes.
  #   * `histogram/2` - a distribution's bins as horizontal bars.

  import Bitwise

  # Braille patterns live at U+2800; each of the 8 dots maps to one bit. The
  # dots are laid out as a 2-wide, 4-tall grid per cell:
  #
  #     (col, row)  dot  bit
  #     (0, 0)       1   0x01      (1, 0)   4   0x08
  #     (0, 1)       2   0x02      (1, 1)   5   0x10
  #     (0, 2)       3   0x04      (1, 2)   6   0x20
  #     (0, 3)       7   0x40      (1, 3)   8   0x80
  @braille_base 0x2800
  @dot_bits %{
    {0, 0} => 0x01,
    {0, 1} => 0x02,
    {0, 2} => 0x04,
    {0, 3} => 0x40,
    {1, 0} => 0x08,
    {1, 1} => 0x10,
    {1, 2} => 0x20,
    {1, 3} => 0x80
  }

  @eighths {"", "▏", "▎", "▍", "▌", "▋", "▊", "▉"}

  @default_width 60
  @default_height 6

  @doc """
  Render `points` (`[%{timestamp: integer, value: number}]`, ascending by
  timestamp) as a braille line chart with box-drawing axes and a relative time
  x-axis.

  Options:
    * `:width`  - plot area width in characters (default #{@default_width})
    * `:height` - plot area height in characters (default #{@default_height})
  """
  @spec line([%{timestamp: integer(), value: number()}], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def line([], _opts), do: {:error, "No data"}

  def line(points, opts) do
    width = opts[:width] || @default_width
    height = opts[:height] || @default_height
    px_w = width * 2
    px_h = height * 4

    values = Enum.map(points, & &1.value)
    timestamps = Enum.map(points, & &1.timestamp)

    v_min = Enum.min(values)
    v_max = Enum.max(values)
    t_min = Enum.min(timestamps)
    t_max = Enum.max(timestamps)

    canvas = plot_curve(points, t_min, t_max, v_min, v_max, px_w, px_h)

    labels = row_labels(v_min, v_max, height)
    label_width = labels |> Enum.map(&String.length/1) |> Enum.max()
    zero_row = zero_row(v_min, v_max, px_h)

    chart =
      labels
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {label, row} ->
        axis = if row == zero_row, do: "┼", else: "┤"
        cells = braille_row(canvas, row, width)
        "#{String.pad_leading(label, label_width)} #{axis}#{String.trim_trailing(cells)}"
      end)

    x_axis = x_axis(t_min, t_max, width, label_width)

    {:ok, chart <> "\n" <> x_axis <> "\n"}
  end

  @doc """
  Render distribution `bins` (`[%{value: number, count: non_neg_integer}]`) as
  horizontal bars. `:width` sets the maximum bar width in characters
  (default 40).
  """
  @spec histogram([%{value: number(), count: non_neg_integer()}], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def histogram([], _opts), do: {:error, "No data"}

  def histogram(bins, opts) do
    width = opts[:width] || 40
    max_count = bins |> Enum.map(& &1.count) |> Enum.max()

    label_width =
      bins
      |> Enum.map(fn %{value: v} -> v |> number_to_string() |> String.length() end)
      |> Enum.max()

    rows =
      Enum.map(bins, fn %{value: value, count: count} ->
        label = value |> number_to_string() |> String.pad_leading(label_width)
        "#{label} │#{bar(count, max_count, width)} #{count}"
      end)

    {:ok, Enum.join(rows, "\n") <> "\n"}
  end

  # ---------------------------------------------------------------- line chart

  # Draw the curve onto a braille canvas: map each point to a pixel and connect
  # consecutive pixels with a straight line so the series reads as a curve
  # rather than disconnected dots.
  defp plot_curve(points, t_min, t_max, v_min, v_max, px_w, px_h) do
    pixels =
      Enum.map(points, fn %{timestamp: t, value: v} ->
        {scale(t, t_min, t_max, 0, px_w - 1), scale(v, v_max, v_min, 0, px_h - 1)}
      end)

    pixels
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(set(%{}, hd(pixels)), fn [p0, p1], canvas ->
      draw_line(canvas, p0, p1)
    end)
  end

  # Map `val` in [lo, hi] onto the integer pixel range [out_lo, out_hi]. A zero
  # span (single point / flat line) lands in the middle of the range.
  defp scale(val, lo, hi, out_lo, out_hi) do
    if hi == lo do
      div(out_lo + out_hi, 2)
    else
      out_lo + round((val - lo) / (hi - lo) * (out_hi - out_lo))
    end
  end

  defp set(canvas, {px, py}) do
    cell = {div(px, 2), div(py, 4)}
    bit = Map.fetch!(@dot_bits, {rem(px, 2), rem(py, 4)})
    Map.update(canvas, cell, bit, &(&1 ||| bit))
  end

  # Bresenham's line algorithm between two pixels. The step direction and the
  # error deltas (dx, dy, sx, sy) are constant for the whole walk, so they ride
  # along in a tuple rather than as separate recursion arguments.
  defp draw_line(canvas, {x0, y0} = p0, {x1, y1}) do
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = if x0 < x1, do: 1, else: -1
    sy = if y0 < y1, do: 1, else: -1
    step(set(canvas, p0), x0, y0, x1, y1, {dx, dy, sx, sy}, dx + dy)
  end

  defp step(canvas, x, y, x, y, _consts, _err), do: canvas

  defp step(canvas, x, y, x1, y1, {dx, dy, sx, sy} = consts, err) do
    e2 = 2 * err
    {x, err} = if e2 >= dy, do: {x + sx, err + dy}, else: {x, err}
    {y, err} = if e2 <= dx, do: {y + sy, err + dx}, else: {y, err}
    step(set(canvas, {x, y}), x, y, x1, y1, consts, err)
  end

  defp braille_row(canvas, row, width) do
    for col <- 0..(width - 1), into: "" do
      case Map.get(canvas, {col, row}) do
        nil -> " "
        mask -> <<@braille_base + mask::utf8>>
      end
    end
  end

  # The value-axis label for the top edge of each character row, top to bottom.
  defp row_labels(v_min, v_max, height) do
    span = v_max - v_min

    for row <- 0..(height - 1) do
      value = v_max - span * row / max(height - 1, 1)
      number_to_string(Float.round(value / 1, 2))
    end
  end

  # The character row that straddles value 0, or nil when 0 is out of range.
  defp zero_row(v_min, v_max, px_h) do
    if v_min <= 0 and v_max >= 0 and v_min != v_max do
      div(scale(0, v_max, v_min, 0, px_h - 1), 4)
    end
  end

  # Build the "└┬───┬" tick row and the time-offset label row beneath it. Labels
  # are offsets from the most recent sample, in a unit chosen from the span.
  defp x_axis(t_min, t_max, width, label_width) do
    margin = label_width + 1
    {divisor, suffix} = axis_unit(t_max - t_min)

    tick_cols = tick_columns(width)

    ticks =
      for col <- 0..(width - 1), into: "" do
        if col in tick_cols, do: "┬", else: "─"
      end

    blank = String.duplicate(" ", margin + 1 + width)

    label_row =
      tick_cols
      |> Enum.reduce(blank, fn col, acc ->
        offset = round((scale_back(col, width, t_min, t_max) - t_max) / divisor)
        text = if col == List.last(tick_cols), do: "#{offset}#{suffix}", else: "#{offset}"
        overlay(acc, margin + 1 + col, text)
      end)
      |> String.trim_trailing()

    "#{String.duplicate(" ", margin)}└#{ticks}\n#{label_row}"
  end

  # The timestamp represented by plot column `col`.
  defp scale_back(col, width, t_min, t_max) do
    if width <= 1, do: t_max, else: t_min + (t_max - t_min) * col / (width - 1)
  end

  defp tick_columns(width) do
    count = max(2, min(6, div(width, 12)))
    step = (width - 1) / (count - 1)

    0..(count - 1)
    |> Enum.map(&round(&1 * step))
    |> Enum.uniq()
  end

  defp axis_unit(span) do
    cond do
      span >= 2 * 86_400 -> {86_400, "d"}
      span >= 2 * 3_600 -> {3_600, "h"}
      span >= 2 * 60 -> {60, "m"}
      true -> {1, "s"}
    end
  end

  defp overlay(base, index, text) do
    {head, tail} = String.split_at(base, index)
    {_, rest} = String.split_at(tail, String.length(text))
    head <> text <> rest
  end

  # ----------------------------------------------------------------- histogram

  defp bar(count, max_count, width) when max_count > 0 do
    eighths = round(count / max_count * width * 8)
    full = div(eighths, 8)
    String.duplicate("█", full) <> elem(@eighths, rem(eighths, 8))
  end

  defp bar(_count, _max_count, _width), do: ""

  # --------------------------------------------------------------------- shared

  defp number_to_string(n) when is_integer(n), do: Integer.to_string(n)

  defp number_to_string(n) when is_float(n) do
    if Float.round(n) == n and abs(n) < 1.0e15 do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end
end
