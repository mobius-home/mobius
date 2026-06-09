# What to measure

What's worth tracking on a device running Mobius, which metric type fits
each signal, and which signals earn a histogram. The framing question for
every metric: *when this device misbehaves in the field, what will I want
to know?* A metric nobody will query is pure cost.

## Choosing a metric type

Mobius scrapes the metrics table once per second into the RRD. That makes
one distinction matter more than anything else:

- **Polled gauges** (e.g. `telemetry_poller` samples every 5 s) produce
  *at most one new value per scrape*. The RRD history already is your
  time series — use `last_value`.
- **Event-driven measurements** (a telemetry event per request, write,
  frame) can produce *many values between scrapes*. `last_value` would
  throw all but one away — use `summary`, and add a histogram when the
  question is a percentile.

Then match the type to the question you'll ask:

| Question | Type |
|---|---|
| "What is it now? How has it trended?" | `last_value` |
| "How many times did X happen?" / "How much in total?" | `counter` / `sum` |
| "What's typical? How noisy?" | `summary` (avg, std_dev, count) |
| "What's the P99? How many exceeded the budget?" | `summary` + histogram |

## BEAM metrics

Add [`telemetry_poller`](https://hex.pm/packages/telemetry_poller) (Phoenix
apps already have it).

A reasonable core set and what each one catches:

```elixir
[
  Metrics.last_value("vm.memory.total", unit: :byte),
  Metrics.last_value("vm.memory.processes", unit: :byte),
  Metrics.last_value("vm.memory.binary", unit: :byte),
  Metrics.last_value("vm.memory.ets", unit: :byte),

  Metrics.last_value("vm.system_counts.process_count"),
  Metrics.last_value("vm.system_counts.port_count"),
  Metrics.last_value("vm.system_counts.atom_count"),

  # Scheduler backlog = CPU saturation. On a 1-core device any
  # sustained value above ~1 means work is queueing.
  Metrics.last_value("vm.total_run_queue_lengths.total"),
  Metrics.last_value("vm.total_run_queue_lengths.io")
]
```

### Atoms

With months of uptime, an atom leak is a *guaranteed* future crash.
The atom table is never garbage-collected; when it hits the limit
(default 1,048,576) the VM dies.

`telemetry_poller` emits `vm.system_counts.atom_count` by default.
The signal is binary: atom count should plateau within minutes
of boot once all modules are loaded. A slope means something is minting
atoms from runtime data. Even a slow slope (a few atoms per
hour) is worth fixing on a device expected to run for a year.

### Worth adding by hand

`telemetry_poller` takes custom measurements. Two cheap ones with high
diagnostic value:

```elixir
{:telemetry_poller,
 measurements: [
   # Built-in process_info measurement: mailbox depth of processes you
   # know are hot paths. A growing message_queue_len is the earliest
   # warning of backpressure failure — long before memory shows it.
   {:process_info,
    name: MyApp.Worker, event: [:my_app, :worker],
    keys: [:message_queue_len, :memory]},

   # Sizes of ETS tables you own and could grow without bound.
   {MyApp.Metrics, :dispatch_table_size, []}
 ],
 period: :timer.seconds(5),
 name: :my_app_poller}
```

```elixir
Metrics.last_value("my_app.worker.message_queue_len"),
Metrics.last_value("my_app.worker.memory", unit: :byte)
```

## Hardware metrics

Nothing emits these for you — poll them yourself with a custom
`telemetry_poller` measurement. All slow-moving trend gauges with
`last_value`.

| Signal | Source | Why |
|---|---|---|
| CPU temperature | `/sys/class/thermal/thermal_zone*/temp` | Thermal throttling explains "mysterious" latency; correlates failures with enclosure/environment |
| Load average | `/proc/loadavg` or `:cpu_sup` (os_mon) | Whole-system CPU pressure, including non-BEAM processes |
| Available memory | `/proc/meminfo` `MemAvailable` | The OOM killer judges the whole system, not `:erlang.memory/0` — the BEAM is not alone on the device |
| Disk usage | `:disksup` or `File.stat` on the writable partition | Mobius itself writes here; a full `/data` breaks more than metrics |
| Flash wear | eMMC EXT_CSD life-time estimate (`mmc extcsd read`) | Poll hourly/daily; a device that will brick itself in 6 months should say so now |
| Cellular signal | VintageNet properties (RSSI / RSRP / SINR) | "Was the modem struggling?" is the first question for any connectivity bug report |
| Network bytes | per-interface rx/tx counters | Cumulative counters — compute the delta in your poller and feed a `sum`, or store the raw counter as `last_value` and diff at query time |
| Supply voltage / battery | ADC, PMIC driver | Brownout precursor; correlates resets with power events |

A typical poller:

```elixir
defmodule MyApp.HW do
  def cpu_temperature do
    with {:ok, raw} <- File.read("/sys/class/thermal/thermal_zone0/temp"),
         {millic, _} <- Integer.parse(raw) do
      :telemetry.execute([:hw, :cpu], %{temperature_c: millic / 1000})
    end
  end
end
```

```elixir
Metrics.last_value("hw.cpu.temperature_c")
```

### Moments belong in the event log

Firmware updates, interface up/down, clock sync, reboot causes, button
presses — these are *events*, not measurements. Don't model them as
metrics.

## What deserves a histogram

Histograms cost real memory and flash on a small device (see
[Histogram configurations](histograms.md) for numbers), and they're
opt-in per metric:

1. **The tail is the question.** If you'd ask "what's the level?" or
   "what's the trend?", `last_value` answers it. If you'd ask "what's
   typical?", the summary average answers it. Histograms answer "what's
   the P99?", "how often did we blow the budget?", "is it bimodal?".
2. **Someone will query a percentile.** On-device via
   `Mobius.Data.quantile/4` / `count_above/4` (alarms, adaptive
   behavior), or off-device (heatmaps, fleet SLOs). If
   no code and no person will ever ask, the summary was enough.

Applied to everything above:

| Metric | Histogram? | Why |
|---|---|---|
| HTTP / API request duration | **yes** | Event-driven, high-rate, tail = the SLO |
| Flash / file write duration | **yes** | Bimodal (cache hit vs erase cycle); "how often does the slow path fire?" is a distribution question |
| Frame period / control-loop jitter | **yes** | Jitter *is* distribution shape; needs tight α — see [the FPS example](histograms.md#camera-fps-instrument-period-not-fps) |
| Sensor / message processing duration | yes, if high-rate | Tens per second: worth it. A few per minute: summary avg already tells the story |
| Ecto query / queue time | yes, if you run a DB | `queue_time` tail exposes pool exhaustion |
| `vm.memory.*` | no | Polled trend; the RRD is the history |
| Run queue lengths | no | Polled — a histogram would profile your 5 s poller, not your scheduler spikes |
| atom / process / port counts | no | Trend gauges; the slope is the answer |
| Temperature, voltage, disk, signal | no | Slow-moving and autocorrelated; you care about now, max, and trend |
| Counters and rates | no | A histogram of a cumulative counter is meaningless; per-interval rates are already in the RRD |

Rule of thumb: **durations of things that happen often -> histogram;
levels of things you sample -> last_value.** When a metric passes the
tests, scope its range and accuracy deliberately — the defaults are far
wider than any real signal needs. [Histogram
configurations](histograms.md) covers tuning.

## A starter set

A reasonable baseline for a connected Nerves device — BEAM health as
trend gauges, hardware environment at a slower cadence, one histogram on
the hot path you actually care about:

```elixir
def metrics do
  [
    # BEAM health (telemetry_poller defaults, every 5 s)
    Metrics.last_value("vm.memory.total", unit: :byte),
    Metrics.last_value("vm.memory.processes", unit: :byte),
    Metrics.last_value("vm.memory.binary", unit: :byte),
    Metrics.last_value("vm.memory.ets", unit: :byte),
    Metrics.last_value("vm.system_counts.process_count"),
    Metrics.last_value("vm.system_counts.atom_count"),
    Metrics.last_value("vm.system_counts.port_count"),
    Metrics.last_value("vm.total_run_queue_lengths.total"),

    # Hardware environment (custom poller, every 30–60 s)
    Metrics.last_value("hw.cpu.temperature_c"),
    Metrics.last_value("hw.memory.available", unit: :byte),
    Metrics.last_value("hw.disk.data_used_percent"),

    # The one hot path that earns a histogram
    Metrics.summary("my_app.request.duration",
      unit: {:native, :millisecond},
      reporter_options: [
        histogram: [
          min_indexable_value: 0.1,
          max_indexable_value: 60_000.0
        ]
      ]
    )
  ]
end
```

Start here, then let field debugging drive additions: every time you SSH
into a device and run a shell command to answer a question, that's a
candidate metric.
