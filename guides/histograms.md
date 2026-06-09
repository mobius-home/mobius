# Histogram configurations

Worked examples of `Telemetry.Metrics.summary` histograms tuned for common
metric shapes. Numbers below are worst-case steady-state cost across the
default retention (348 snapshots), measured with
`benchmarks/histogram_cost.exs`.

## Quick reference

| Metric shape | Range | α | Bins | Heap | Disk |
|---|---|---|---|---|---|
| HTTP request latency | 0.1 – 60_000 ms | 0.1 (default) | 67 | 839 KB | 152 KB |
| Camera frame period (not fps — see below) | 8 – 100 ms | 0.01 | 128 | 1.4 MB | 234 KB |
| Memory bytes used | 1 KB – 1 GB | 0.1 | 70 | 874 KB | 156 KB |
| Flash write duration (bimodal) | 0.1 – 10_000 ms | 0.05 | 117 | 1.3 MB | 220 KB |
| Network throughput (bytes/s) | 1 KB/s – 10 MB/s | 0.1 | 47 | 645 KB | 125 KB |
| Boot time (regression watch) | 100 – 60_000 ms | 0.02 | 161 | 1.7 MB | 279 KB |

## HTTP request latency

General-purpose; ±10% is plenty for "did P99 cross budget?"

```elixir
Telemetry.Metrics.summary("http.request.duration",
  measurement: :duration,
  unit: {:native, :millisecond},
  reporter_options: [
    histogram: [
      min_indexable_value: 0.1,        # below 0.1 ms = instant
      max_indexable_value: 60_000.0    # cap at 60 s
      # α defaults to 0.1
    ]
  ]
)
```

## Camera FPS — instrument *period*, not fps

FPS needs ±1% (60 → 54 fps is visible jank, ±10% wouldn't catch it). The
direct approach wastes 2/3 of bins:

```elixir
# Don't do this — 356 bins, 3.8 MB heap.
histogram: [min_indexable_value: 0.1, max_indexable_value: 120.0, relative_accuracy: 0.01]
```

DDSketch bin density is logarithmic — at α=0.01 a bin near 1 fps is
~0.02 fps wide, a bin near 60 fps is ~1.2 fps wide. ~240 of those 356
bins sit in the [0.1, 20] fps region where you don't
need sub-fps resolution.

Histogram the *frame period* (ms/frame = 1000/fps) instead:

```elixir
Telemetry.Metrics.summary("camera.frame_period_ms",
  measurement: :period_ms,
  reporter_options: [
    histogram: [
      min_indexable_value: 8.0,        # 8 ms = 125 fps
      max_indexable_value: 100.0,      # 100 ms = 10 fps
      relative_accuracy: 0.01
    ]
  ]
)
```

128 bins, 1.4 MB heap — **3× cheaper for the same precision**. Period
and fps are reciprocal and α is relative, so ±1% on period = ±1% on
fps. Convert at the dashboard: `fps = 1000 / period_ms`.

### When the inverse trick helps

Whenever you care about precision at *high* values and not too much
about *low* values:

| Signal | Better domain |
|---|---|
| Frame rate (fps) | Frame period (ms) |
| Throughput (ops/sec) | Time per op (ms) |
| Sampling rate (Hz) | Sample interval (ms) |
| Bandwidth (Mbps) | Time per MB |

## Memory bytes used

Slowly-changing trend signal. Default 10% relative error is probably fine
on a dashboard.

```elixir
Telemetry.Metrics.summary("vm.memory.bytes",
  measurement: :bytes,
  reporter_options: [
    histogram: [
      min_indexable_value: 1_024.0,             # 1 KB floor
      max_indexable_value: 1_073_741_824.0      # 1 GB cap
    ]
  ]
)
```

## Flash write duration (bimodal)

Most writes are fast (cache, ~ms), some are slow (erase cycles, hundreds
of ms). The interesting question is "how often does the slow path fire?",
so capturing tail shape matters. 0.05 may be the sweet spot.

```elixir
Telemetry.Metrics.summary("flash.write.duration",
  measurement: :duration,
  unit: {:native, :millisecond},
  reporter_options: [
    histogram: [
      min_indexable_value: 0.1,
      max_indexable_value: 10_000.0,
      relative_accuracy: 0.05
    ]
  ]
)
```

## Network throughput (bytes/sec)

Cellular/wifi throughput swings wildly; "are we getting decent throughput?"
doesn't need precision.

```elixir
Telemetry.Metrics.summary("network.throughput.bytes_per_sec",
  measurement: :bps,
  reporter_options: [
    histogram: [
      min_indexable_value: 1_024.0,            # 1 KB/s
      max_indexable_value: 10_485_760.0        # 10 MB/s
    ]
  ]
)
```

## Picking α

| Use case | α |
|---|---|
| Alerting / SLO checks | 0.1 (default) |
| Smooth percentile lines on a dashboard | 0.05 |
| Regression detection, A/B comparisons | 0.02 |
| Sub-percent precision (FPS, RT control) | 0.01 |
| Below 0.01 | almost never useful |

Cost scales as `1/α`. Doubling precision doubles memory.

## Picking the range

- **`:min_indexable_value`** = noise floor (not zero). Values below fold
  into a single zero bucket. 0.1 ms, 1 KB — whatever "basically nothing"
  means for this metric.
- **`:max_indexable_value`** = realistic ceiling + margin. Values above
  clamp to the top bin (default `:on_overflow: :clamp`) — outliers still
  count, they just lose sub-bin resolution. This caps bin growth.

Use `benchmarks/histogram_cost.exs` to measure your own config before
committing.

## Memory and disk cost

Histogram cost lives in two places:

1. **Live ETS.** One counter row per populated bin in the metrics table.
2. **Snapshot history.** Every per-second/minute/hour/day snapshot
   kept in the Scraper process heap captures every populated bin.
   This dominates memory usage.

Bin counters are **strictly cumulative**: a magnitude observed once
keeps its row forever. Old snapshots roll off the history but the
live bins never do. So a deployed metric drifts toward worst-case bin
count over uptime. Plan with worst case.

Bin count is bounded by `ceil(log_γ(max/min)) ≈ (log value range) / α`.
At default α=0.1 that's ~12 bins per decade:

| α | bins/decade | quantile error |
|---|---|---|
| 0.005 | ~230 | ±0.5% |
| 0.01 | ~115 | ±1% |
| 0.02 | ~58 | ±2% |
| 0.05 | ~23 | ±5% |
| **0.1 (default)** | **~12** | **±10%** |
| 0.2 | ~6 | ±20% |

The default is loose on purpose: Mobius runs on embedded, ±10% on a
P99 is plenty for alerting and SLOs. Tighten only when you actually
need precision (regression detection, FPS jitter).

### Worst-case cost by scenario

Measured by `benchmarks/histogram_cost.exs` against the default
retention (60d/48h/120m/120s = 348 snapshots) at α=0.1. Plain-summary
baseline for comparison: 2.8 KB ETS, 114 KB heap, 54 KB disk
(constant).

| Scenario | Live ETS | Heap | Disk | Bins |
|---|---|---|---|---|
| HTTP latency (0.1–60_000 ms) | 13.7 KB | 838.9 KB | 155.7 KB | 67 |
| narrow latency (1–100 ms) | 6.5 KB | 318.7 KB | 97.7 KB | 24 |
| wide latency (1 ms–10 s) | 10.2 KB | 644.8 KB | 128.7 KB | 47 |
| very wide (1 µs–1 hr in µs) | 20.7 KB | 1.2 MB | 215.0 KB | 111 |
| defaults (1.0e-9 .. 1.0e18) | 71.8 KB | 3.2 MB | 541.1 KB | 311 |

### Levers, ranked

1. **Tighten the range.** Most realistic metrics live in 2–4 decades,
   not 27. Setting `:max_indexable_value` and `:min_indexable_value`
   cuts memory 4–10× over the wide-open defaults.
2. **Loosen α.** Default 0.1 is loose already; α=0.2 halves bins again
   at the cost of ±20% quantile error.
3. **Shorten retention.** Pass a smaller `:database`:
   ```elixir
   {Mobius, metrics: ..., database: Mobius.RRD.new(seconds: 60, minutes: 60, hours: 0, days: 0)}
   ```
4. **Be selective.** Histograms are opt-in per metric — only enable on
   the ones you'll actually query percentiles for.
