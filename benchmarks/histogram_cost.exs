# Histogram cost per scenario — the "Worst-case cost by scenario" table in
# the README.
#
# Saturates each scenario's value range with synthetic bin counters, fills
# the default snapshot history across all four retention layers, and
# reports live ETS, in-heap, and persisted disk size per histogram metric.
#
# Run from the project root:
#
#   elixir benchmarks/histogram_cost.exs

Mix.install([
  {:mobius, path: Path.expand("..", __DIR__)}
])

defmodule HistogramCost do
  alias Mobius.{DDSketch, MetricsTable, RRD}

  @scenarios [
    {"README example (0.1–60_000 ms)", 0.1, 60_000.0},
    {"narrow latency (1–100 ms)", 1.0, 100.0},
    {"wide latency (1 ms–10 s)", 1.0, 10_000.0},
    {"very wide (1 µs–1 hr in µs)", 1.0, 3_600_000_000.0},
    {"defaults (1.0e-9 .. 1.0e18)", 1.0e-9, 1.0e18}
  ]

  @observations 100_000

  def run() do
    rows =
      for {label, lo, hi} <- @scenarios do
        :rand.seed(:exsss, {1, 2, 3})
        sketch = DDSketch.new(min_indexable_value: lo, max_indexable_value: hi)

        ets_bytes = measure_live_ets(sketch, lo, hi)
        bins = bin_count(sketch, lo)
        {heap, disk} = measure_full_rrd(bins)

        {label, ets_bytes, heap, disk, bins}
      end

    print_table(rows)
  end

  # -------------------------------------------------------------- live ETS

  defp measure_live_ets(sketch, lo, hi) do
    table = :"hist_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :set])

    MetricsTable.put(table, "metric", :summary, lo, %{})

    log_lo = :math.log(lo)
    log_hi = :math.log(hi)

    for _ <- 1..@observations do
      v = :math.exp(log_lo + :rand.uniform() * (log_hi - log_lo))
      MetricsTable.put(table, "metric", :summary, v, %{})

      case DDSketch.bin_key_for_value(sketch, v) do
        :drop -> :ok
        bin_key -> MetricsTable.inc_histogram_bin(table, "metric", bin_key, %{})
      end
    end

    bytes = :ets.info(table, :memory) * :erlang.system_info(:wordsize)
    :ets.delete(table)
    bytes
  end

  # ------------------------------------------------------------ Snapshot history

  defp measure_full_rrd(n_bins) do
    pos_bins = Map.new(1..n_bins, fn i -> {i, 100} end)
    sidecar = %{{"metric", %{}} => {pos_bins, %{}, 0}}
    summary = summary_record()
    snapshot = {[summary], sidecar}

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

  defp bin_count(sketch, lo) do
    lo_idx = ceil(:math.log(lo) / sketch.log_gamma)
    hi_idx = sketch.max_positive_index
    hi_idx - lo_idx + 1
  end

  # ------------------------------------------------------- output / format

  defp print_table(rows) do
    IO.puts("")
    IO.puts("## Worst-case cost by scenario (α=#{DDSketch.new().relative_accuracy})")
    IO.puts("")

    IO.puts(
      "Measured by `benchmarks/histogram_cost.exs` against the default " <>
        "retention (60d/48h/120m/120s = 348 snapshots) on a " <>
        "#{:erlang.system_info(:wordsize) * 8}-bit system."
    )

    IO.puts("")
    IO.puts("| Scenario | Live ETS | Heap | Disk | Bins |")
    IO.puts("|---|---|---|---|---|")

    for {label, ets, heap, disk, bins} <- rows do
      IO.puts("| #{label} | #{human(ets)} | #{human(heap)} | #{human(disk)} | #{bins} |")
    end

    IO.puts("")
  end

  defp human(b) when b < 1024, do: "#{b} B"
  defp human(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp human(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"
end

HistogramCost.run()
