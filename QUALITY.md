# Quality review — histograms branch

Critical review of the histogram work (`e191b9c..c76d8d7`, `main...histograms`).
Findings verified against the code; line references are to the branch.

## Critical

### 1. `mix.exs` / `mix.lock` regressed to a stale pre-0.7.0 state
`mix.exs:4`

The branch reverts infrastructure unrelated to histograms — almost certainly a
stale file committed from an older checkout:

- version `0.7.0` → `0.6.1` (would publish *behind* the released version)
- `cli/0` and the entire `precommit` alias deleted (`--warnings-as-errors`,
  `credo --strict --all`, `dialyzer`, `hex.audit`, `deps.unlock --unused`) —
  the quality gates stop running
- `elixir: "~> 1.15"` → `"~> 1.11"`; ex_doc `~> 0.40` → `~> 0.24`, dialyxir
  `~> 1.4` → `~> 1.0`, credo `~> 1.7` → `~> 1.4`
- `circular_buffer "~> 0.4 or ~> 1.0"` → `"~> 0.4.0"`, and `mix.lock` reverts
  circular_buffer 1.0.1 → 0.4.2 — so the branch is tested against a different
  dependency tree than main validated, and conflicts with downstreams on the
  1.0 line
- ex_doc `assets:` reverted to the deprecated string form

This needs to be restored from main before merge.

## Bugs

### 2. Counter reset crashes every histogram query path — **FIXED**
`lib/mobius/exports/histogram.ex`, `lib/mobius/charts.ex`, `lib/mobius/dd_sketch.ex`

`DDSketch.delta/2` raised `ArgumentError` on any negative per-bin delta, and
both window-reconstruction paths called it unguarded. A reset is a known,
reachable state: the live counters (`metrics_table` ETS dump) and the
snapshot history (`history` file) persist as **separate files**; lose the
first while the second survives a reboot and the post-reboot snapshot has
lower cumulative counts than the pre-reboot one. Every histogram query
spanning the reset crashed, while the sibling summary path already guarded
exactly this (`summary_windows`' `reports > 0` check).

**Fix:** `DDSketch.delta/2` now returns `{:ok, sketch} | {:error, :reset}`
(a reset is a data condition, not a caller bug; mismatched accuracies still
raise). `Charts.window_sketches` skips the interval straddling the reset,
mirroring `summary_windows`. `Exports.Histogram.build_window_sketch` falls
back to the later snapshot alone — everything observed since the reset —
rather than dropping the whole window. Covered by unit tests on `delta/2`
and end-to-end reset tests (instance restart with the metrics-table dump
deleted) in both `exports/histogram_test.exs` and `charts_test.exs`;
behavior documented in `guides/histograms.md`.

### 3. Missing baseline silently attributes all-time counts to the window
`lib/mobius/exports/histogram.ex:147-169`

`build_window_sketch` anchors the baseline at `snapshot_at_or_before(from - 1)`
and falls back to an **empty sketch** when none is found. That's correct when
the metric started inside the window, but wrong when the pre-window baseline
has rolled out of RRD retention (ring buffers, bounded at 60 days by default):
the "window" delta becomes the full cumulative distribution since the metric
started. For a long-lived metric queried with e.g. `last: {60, :day}`, the
over-count is unbounded and the failure is silent — plausible-looking but
wrong quantiles/counts. The code cannot currently distinguish "metric is new"
from "baseline rolled off"; at minimum the latter should be detectable
(window `from` older than the oldest retained snapshot) and surfaced.

### 4. Charts and Exports select different snapshots for the same window
`lib/mobius/charts.ex:373` vs `lib/mobius/exports/histogram.ex:147`

`Charts.window_sketches` filters with `to - ts <= @max_history_seconds`
(60 days); `Exports.Histogram.build_window_sketch` applies no cap and anchors
at `from - 1`. For the same window args the two APIs operate on different
snapshot sets, so `quantiles_over_time` and `Exports.quantile` can disagree
about the same data. Symptom of the duplication in finding 8.

### 5. Histogram config key derived two different ways — mismatch drops valid data
`lib/mobius/events.ex:136` vs `lib/mobius/rrd.ex:236`, `lib/mobius/metrics_table.ex:73`

The current-config side keys on **declared** tags (`Enum.sort(metric.tags)`);
the persisted side keys on **recorded** meta keys
(`Map.keys(tags) |> Enum.sort()`). `extract_tags` does
`Map.take(tag_values, metric.tags)`, so recorded keys are a subset of declared
— whenever a declared tag is absent from event metadata, the keys diverge, the
compatibility lookup returns `nil`, and valid histogram data is dropped on
load with a misleading "config changed" warning. One shared `config_key`
helper would make this divergence impossible (see finding 8).

### 6. Handler-leak fix only covers clean shutdown
`lib/mobius/registry.ex:68,121`

The new `trap_exit` + `terminate/2` detaches handlers on clean shutdown — good.
But handler ids embed `self()`, and telemetry never auto-detaches on process
death. If a Registry dies without `terminate` running (`:brutal_kill`, crash
loop), the old handlers stay attached; the restarted Registry attaches under a
new pid-based id, and every event is **double-counted** from then on. A
deterministic id (no pid) plus detach-before-attach would close both paths.
(Partially pre-existing, but this branch's commit message claims to fix
handler leakage, so the residual hole is worth noting.)

## Performance

### 7. Throwaway `DDSketch.new/1` on every telemetry event
`lib/mobius/events.ex:86`

`maybe_record_histogram` runs `histogram_opts/1` keyword parsing plus
`DDSketch.new(opts)` — four validation guards, two `:math.log` calls, `ceil`,
and a 10-field struct allocation — on **every event** of every
histogram-enabled summary metric, only to compute one bin key. The resolved
config already exists (`Events.histogram_configs/1` at startup, cached in ETS
by `MetricsTable`), but the telemetry attach config
(`lib/mobius/registry.ex:71`) doesn't carry it. Resolve the sketch (or just
`{gamma, log_gamma, min, max, on_overflow}`) once at attach time and pass it
through the handler config. On an embedded device this is the hottest path in
the library. (Invalid opts are *not* a correctness issue — they fail fast at
supervisor init via the same `DDSketch.new` call; verified.)

### Smaller efficiency notes (all verified)

- `lib/mobius/exports/histogram.ex:45` — pulls `Scraper.all_histograms/1`
  (entire history copied out of the GenServer) then scans it twice in
  `snapshot_at_or_before`; `all_histograms/2` already accepts `from:`/`to:`.
- `lib/mobius/metrics_table.ex:68` — startup reconcile does a full-table
  `:ets.select` and filters for `:hist` rows in Elixir; a match spec guard on
  the key shape would avoid materializing every metric row.
- `lib/mobius/dd_sketch.ex:530` — `ordered_entries/1` re-sorts on every call
  (`quantile`, `min`, `max`, `count_in_range` each re-sort the same bins);
  `quantiles/2` re-walks from rank 0 per quantile instead of one cursor pass.
- `lib/mobius/dd_sketch.ex:511` — `bin_map_delta` allocates two MapSets and a
  union; a `Map.merge`-style fold does the same with no intermediates.

## Duplication / structure

### 8. The query layer is written twice (and a half)

The dominant structural problem: `Mobius.Charts` re-implements what
`Mobius.Exports.Histogram` does instead of sharing a windowing layer, and
histogram-config compatibility is re-implemented per store. Concretely, each
of these exists in multiple copies that must be fixed in lockstep:

| Logic | Copies |
|---|---|
| Window resolution (`resolve_window`/`last_seconds` + unit table) | `exports/metrics.ex:87`, `exports/histogram.ex:125`, `charts.ex:440` — with differing defaults and return shapes |
| Snapshot-pair delta reconstruction (`from_snapshot` + `delta`) | `charts.ex:364` (`window_sketches`), `charts.ex:405` (`summary_windows`), `exports/histogram.ex:147` |
| Config-key + compare-and-drop | `events.ex:136`, `rrd.ex:236`, `metrics_table.ex:73` (already divergent — finding 5) |
| Sketch-config field list (4 fields) | `events.ex:142` (`sketch_config`), `charts.ex:390` (`sketch_opts`) — wants a public `DDSketch.config/1` |
| Within-bin estimator `2γ^i/(γ+1)` | `dd_sketch.ex:550` and copied verbatim in `charts.ex:355` — `DDSketch` should expose ordered `{value, count}` entries publicly instead of only raw `bins/1` |

Findings 2 (since fixed), 4, and 5 are all *consequences* of these copies
drifting — and the fix for finding 2 indeed had to be applied at two call
sites, one per copy. A single shared window-reconstruction helper and a
single `config_key`/`sketch_config` source would fix the remaining bugs and
the duplication at once.

### 9. Histogram internals leak into generic infrastructure

- `lib/mobius/scraper.ex:199` — `build_snapshot` hand-rolls the
  `{:hist, :pos/:neg/:zero, idx}` → `{pos, neg, zero}` assembly; the DDSketch
  bin/snapshot encoding now lives in two modules. A `DDSketch.to_snapshot`-side
  helper (mirror of the existing `from_bins/2`) would keep it in one.
- `lib/mobius/registry.ex:121` — the stale-entry reaper exempts hist rows by
  matching the bin-tuple shapes; a new bin kind would be silently
  garbage-collected. Deriving keep/remove from "is this metric still
  registered with histograms enabled" would not need to know the encoding.
- `lib/mobius/charts.ex:418` — `summary_windows` open-codes the field-wise
  inverse of `Summary.update/2` (`accumulated`, `accumulated_sqrd`,
  `reports`); a `Summary.delta/2` next to the accumulator definition would
  keep the field knowledge in one module.

### Minor

- `lib/mobius/dd_sketch.ex:355` — `count_in_range` carries an
  `include_lo`/`include_hi` keyword API plus `:neg_inf`/`:pos_inf` sentinels
  for exactly three callers that each pass fixed literals; three one-line
  folds would be simpler.
- `lib/mobius/dd_sketch.ex:97` — `max_positive_index` is stored in the struct
  but fully derived from `max_indexable_value`/`log_gamma` and used once.
- `lib/mobius/metrics_table.ex:52` — the hidden `@histogram_configs_key` atom
  row in the metrics ETS table works because current match specs only select
  3-tuples; any future broader select/dump must remember to skip it.

## Checked and found sound

- **Reusing serialization version byte 3 with a new payload shape**
  (`lib/mobius/rrd.ex:212`) is acceptable: v3 has never shipped — the latest
  release v0.7.0 (2026-05-22) writes v2, and v3 only exists on unreleased
  main (`2e0260c`, this branch's merge base). The branch's `<<2, …>>` clause
  migrates released-format files correctly. Only devices tracking unreleased
  main via git (and dev checkouts switching between main and this branch)
  would see their history file rejected as `:corrupt` and discarded — worth
  one line in the changelog, nothing more.
- **Quantile rank math** (`q * (total - 1)`, `pick_at_rank`) matches the
  Datadog reference implementation's convention exactly; the documented
  relative-accuracy guarantee is validated by the test suite (all 54
  dd_sketch tests pass, including uniform 1..10,000 accuracy bounds).
- **One-time drop of pre-meta-row ETS dumps** (`reconcile_histogram_bins`) is
  documented, logged, and loses nothing on a real main→branch upgrade (no
  `:hist` rows exist in old dumps).
- **Invalid histogram opts** fail fast at supervisor init, not per-event.
- **MetricsTable and Scraper** derive histogram configs from the same `args`;
  they cannot diverge.
- **Legacy snapshot-shape clauses** in `scraper.ex` are defensive dead code on
  this branch (load migrates v1/v2 to the tuple shape), not a live hazard.
