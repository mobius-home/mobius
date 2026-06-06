# Realistic distribution cost — the "Realistic — early life" table in the
# README.
#
# Feeds the README's example range (0.1 .. 60_000 ms) a log-normal HTTP
# latency distribution (most observations cluster around the median, a
# long but bounded tail) and reports how many bins get populated versus
# the worst-case ceiling.
#
# Bin counters are strictly cumulative — these numbers describe early
# life on a fresh device. Over uptime, rare outliers will drift the bin
# set toward the worst-case row.
#
# Run from the project root:
#
#   elixir benchmarks/realistic_distribution.exs

Mix.install([
  {:mobius, path: Path.expand("..", __DIR__)}
])

defmodule RealisticDistribution do
  alias Mobius.{DDSketch, MetricsTable, RRD}

  @lo 0.1
  @hi 60_000.0
  @observations 100_000

  @scenarios [
    {"log-normal σ=0.5 (tight, P99 ≈ 250 ms)", 0.5},
    {"log-normal σ=1.0 (fat tail, P99 ≈ 1 s)", 1.0}
  ]

  def run() do
    worst_bins = bin_count_for(@lo, @hi)

    rows =
      for {label, sigma} <- @scenarios do
        :rand.seed(:exsss, {1, 2, 3})
        sketch = DDSketch.new(min_indexable_value: @lo, max_indexable_value: @hi)
        sampler = lognormal_sampler(:math.log(50.0), sigma)

        {ets, bins} = measure_live_ets(sketch, sampler)
        {heap, disk} = measure_full_rrd(bins)
        pct = round(bins / worst_bins * 100)

        {label, ets, heap, disk, bins, pct}
      end

    print_table(rows, worst_bins)
  end

  defp bin_count_for(lo, hi) do
    sketch = DDSketch.new(min_indexable_value: lo, max_indexable_value: hi)
    lo_idx = ceil(:math.log(lo) / sketch.log_gamma)
    hi_idx = sketch.max_positive_index
    hi_idx - lo_idx + 1
  end

  defp lognormal_sampler(mu, sigma) do
    fn ->
      u1 = :rand.uniform()
      u2 = :rand.uniform()
      z = :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
      :math.exp(mu + sigma * z)
    end
  end

  # ------------------------------------------------------------- measurements

  defp measure_live_ets(sketch, sampler) do
    table = :"hist_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :set])

    MetricsTable.put(table, "metric", :summary, 50.0, %{})

    for _ <- 1..@observations do
      v = sampler.()
      MetricsTable.put(table, "metric", :summary, v, %{})

      case DDSketch.bin_key_for_value(sketch, v) do
        :drop -> :ok
        bin_key -> MetricsTable.inc_histogram_bin(table, "metric", bin_key, %{})
      end
    end

    bytes = :ets.info(table, :memory) * :erlang.system_info(:wordsize)
    # Bin rows = total rows minus the one summary row.
    bins = :ets.info(table, :size) - 1
    :ets.delete(table)
    {bytes, bins}
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

  defp print_table(rows, worst_bins) do
    IO.puts("")

    IO.puts(
      "## Realistic — early life (range 0.1 .. 60_000 ms, α=#{DDSketch.new().relative_accuracy})"
    )

    IO.puts("")

    IO.puts(
      "100k observations from a log-normal HTTP latency profile (median 50 ms) " <>
        "into the README example's sketch. Worst-case ceiling for this range: " <>
        "#{worst_bins} bins."
    )

    IO.puts("")
    IO.puts("| Distribution | Live ETS | Heap | Disk | Bins | % of worst case |")
    IO.puts("|---|---|---|---|---|---|")

    for {label, ets, heap, disk, bins, pct} <- rows do
      IO.puts("| #{label} | #{human(ets)} | #{human(heap)} | #{human(disk)} | #{bins} | #{pct}% |")
    end

    IO.puts("")
  end

  defp human(b) when b < 1024, do: "#{b} B"
  defp human(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024)} KB"
  defp human(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"
end

RealisticDistribution.run()
