# Benchmarks

Standalone `Mix.install` scripts that reproduce the histogram cost
numbers cited in the main README and the histograms guide. Each script
prints a paste-ready markdown table.

Run from the project root:

```sh
elixir benchmarks/histogram_cost.exs           # Worst-case cost by scenario
elixir benchmarks/tuning_grid.exs              # α × range grid
elixir benchmarks/realistic_distribution.exs   # Log-normal early-life cost
```

Each is fully self-contained — it resolves the local Mobius checkout
via `Mix.install([{:mobius, path: "..."}])`, so you don't need a `mix`
project context to run them. First run takes a moment to fetch and
compile dependencies; subsequent runs are fast.

## What each script measures

| Script | Table | Used in |
|---|---|---|
| `histogram_cost.exs` | Live ETS / Heap / Disk per scenario | README "Worst-case cost by scenario" |
| `tuning_grid.exs` | `bins · heap / disk` per (range, α) cell | README "Tuning grid" |
| `realistic_distribution.exs` | Early-life cost under a log-normal HTTP latency distribution | README "Realistic — early life" |

## Updating the README

When tuning defaults or restructuring the on-disk format, re-run the
scripts and paste the resulting tables over the matching sections in
`README.md`. Numbers in the README and `guides/histograms.md` should
always reflect the current `main` branch behaviour — these scripts are
the single source of truth.

## Methodology

All three scripts use the same approach:

1. Construct a Mobius `DDSketch` configured for the scenario.
2. For the worst-case measurements, synthesise one bin counter per
   index that the sketch could ever allocate. For the realistic
   measurements, draw 100k samples from the chosen distribution and
   feed them through the real ingress path.
3. Fill the default snapshot history (`60d/48h/120m/120s = 348 slots`)
   with the resulting per-snapshot payload at timestamps that span all
   four retention layers.
4. Report:
   - **Live ETS**: `:ets.info(table, :memory) * wordsize`
   - **Heap**: `:erts_debug.flat_size(history) * wordsize`
   - **Disk**: `Mobius.RRD.save(history) |> IO.iodata_length()`

The flat_size measurement is structural — actual BEAM-allocated heap
in a running Scraper process sits roughly 1.5–2× higher due to GC
slack between scrapes. Use the published heap figures as the lower
bound when sizing for production.
