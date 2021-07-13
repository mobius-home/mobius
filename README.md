# Mobius

Library for localized telemetry metrics

## Installation

```elixir
def deps do
  [
    {:mobius, "~> 0.1.0"}
  ]
end
```

## Usage

Add `Mobius` to your supervision tree and pass in the metrics you want to track.

```elixir
def start(_type, _args) do
  metrics = [
    Metrics.last_value("my.telemetry.event"),
  ]

  children = [
    # ... other children ....
    {Mobius, metrics: metrics}
    # ... other children ....
  ]

  # See https://hexdocs.pm/elixir/Supervisor.html
  # for other strategies and supported options
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Charting historical metrics

Mobius tracks metrics overtime in a circular buffer and allows you to graph
metric values over time:

```
iex> Mobius.History.chart()
                Event: vm.memory.total, Metric: :last_value, Tags: %{}

34355808.00 ┤
34253736.73 ┤                                                  ╭────╮              ╭────╮
34151665.45 ┤                                             ╭────╯    ╰──────────────╯    ╰─────────
34049594.18 ┤         ╭────╮          ╭─────────╮    ╭────╯
33947522.91 ┤         │    ╰──────────╯         ╰────╯
33845451.64 ┤         │
33743380.36 ┤    ╭────╯
33641309.09 ┤    │
33539237.82 ┤    │
33437166.55 ┤    │
33335095.27 ┼────╯
```

