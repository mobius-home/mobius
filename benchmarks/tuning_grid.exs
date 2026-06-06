# Tuning grid — the (α × value range) cost matrix in the README.
#
# For each (range, α) cell, computes the worst-case bin count, fills the
# default snapshot history, and reports the in-heap and on-disk size of
# one histogram metric. Output is the markdown grid used in the README.
#
# Run from the project root:
#
#   elixir benchmarks/tuning_grid.exs

Mix.install([
  {:mobius, path: Path.expand("..", __DIR__)}
])

defmodule TuningGrid do
  alias Mobius.{DDSketch, RRD}

  @ranges [
    {"sensor (1–1_000 ms)", 1.0, 1_000.0},
    {"web latency (0.1–30_000 ms)", 0.1, 30_000.0},
    {"wide (1 µs–1 hr in µs)", 1.0, 3_600_000_000.0}
  ]

  @alphas [0.01, 0.02, 0.05, 0.1, 0.2]

  def run() do
    rows =
      for {label, lo, hi} <- @ranges do
        cells =
          for alpha <- @alphas do
            bins = bin_count(lo, hi, alpha)
            {heap, disk} = measure_full_rrd(bins)
            {bins, heap, disk}
          end

        {label, cells}
      end

    print_table(rows)
  end

  defp bin_count(lo, hi, alpha) do
    sketch = DDSketch.new(min_indexable_value: lo, max_indexable_value: hi, relative_accuracy: alpha)
    lo_idx = ceil(:math.log(lo) / sketch.log_gamma)
    hi_idx = sketch.max_positive_index
    hi_idx - lo_idx + 1
  end

  defp measure_full_rrd(n_bins) do
    pos_bins = Map.new(1..n_bins, fn i -> {i, 100} end)
    histograms = %{{"metric", %{}} => {pos_bins, %{}, 0}}
    summary = summary_record()
    snapshot = {[summary], histograms}

    rrd = fill_rrd(RRD.new(), snapshot)
    word = :erlang.system_info(:wordsize)
    heap = :erts_debug.flat_size(rrd) * word
    disk = rrd |> RRD.save() |> IO.iodata_length()
    {heap, disk}
  end

  defp fill_rrd(rrd, snapshot) do
    timestamps =
      (for(d <- 0..59, do: d * 86_400) ++
         for(h <- 0..47, do: 60 * 86_400 + h * 3_600) ++
         for(m <- 0..119, do: 60 * 86_400 + 48 * 3_600 + m * 60) ++
         for(s <- 0..119, do: 60 * 86_400 + 48 * 3_600 + 120 * 60 + s))

    Enum.reduce(timestamps, rrd, fn ts, acc -> RRD.insert(acc, ts, snapshot) end)
  end

  defp summary_record() do
    %{
      timestamp: 0,
      name: "metric",
      type: :summary,
      value: %{min: 1, max: 1000, accumulated: 50_000, accumulated_sqrd: 5_000_000, reports: 100},
      tags: %{}
    }
  end

  defp print_table(rows) do
    IO.puts("")
    IO.puts("## Tuning grid — worst-case `bins · heap / disk` per histogram")
    IO.puts("")

    header = "| range \\ α | " <> Enum.map_join(@alphas, " | ", &"α=#{&1}") <> " |"
    sep = "|---|" <> Enum.map_join(@alphas, "|", fn _ -> "---" end) <> "|"
    IO.puts(header)
    IO.puts(sep)

    for {label, cells} <- rows do
      cell_strs =
        Enum.map(cells, fn {bins, heap, disk} ->
          "#{bins} · #{human(heap)} / #{human(disk)}"
        end)

      IO.puts("| #{label} | #{Enum.join(cell_strs, " | ")} |")
    end

    IO.puts("")
  end

  defp human(b) when b < 1024, do: "#{b} B"
  defp human(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024)} KB"
  defp human(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"
end

TuningGrid.run()
