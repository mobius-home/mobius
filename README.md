# Mobius

[![CircleCI](https://circleci.com/gh/mattludwigs/mobius/tree/main.svg?style=svg)](https://circleci.com/gh/mattludwigs/mobius/tree/main)

Library for localized telemetry metrics

## Installation

```elixir
def deps do
  [
    {:mobius, "~> 0.2.0"}
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

Mobius scrapes current metric information at different resolutions:

* `:minute` - metrics over the last minute in 1 second intervals
* `:hour` - metrics over the last hour in 1 minute intervals 
* `:day` - metrics over the last day in 1 hour intervals
* `:week` - metrics over the last week in 1 day intervals
* `:month` - metrics over the last 31 days in 1 day intervals

### Configure persistence directory

By default Mobius will try to save metric data for all resolutions and the
current value when the erlang system exists gracefully. This makes Mobius useful
for Nerves devices that have to reboot after doing a planned firmware update.
The default direction Mobius will try to persist data to is the `/data`
directory as this is friendly to Nerves devices. If you want Mobius to store
data in a different location you can pass that into Mobius when you start it:

```elixir

children = [
   # ... other children ...
   {Mobius, metrics: metrics, persistence_dir: "/tmp"}
   # ... other children ...
]
```

### Charting historical metrics

Mobius tracks metrics overtime in a circular buffer and allows you to graph
metric values over time using `Mobius.Charts.plot/3`:

```
iex> Mobius.Charts.plot("vm.memory.total")
                Metric Name: vm.memory.total, Tags: %{}

34355808.00 ┤
34253736.73 ┤                                    ╭──╮    ╭────╮
34151665.45 ┤                               ╭────╯  ╰────╯    ╰───
34049594.18 ┤         ╭────╮    ╭────╮ ╭────╯
33947522.91 ┤         │    ╰────╯    ╰─╯
33845451.64 ┤         │
33743380.36 ┤    ╭────╯
33641309.09 ┤    │
33539237.82 ┤    │
33437166.55 ┤    │
33335095.27 ┼────╯
```

By default Mobius will plot the metrics over the last minute. You can see other
resolutions by passing the `:resolution` option:

```
iex> Mobius.Charts.plot("vm.memory.total", %{}, resolution: :hour)
                Metric Name: vm.memory.total, Tags: %{}

75190128.00 ┤
75152538.46 ┤                    ╭╮                                  ╭╮╭
75114948.92 ┤                    ││   ╭╮   ╭─╮ ╭╮ ╭╮      ╭╮         │││
75077359.38 ┤            ╭╮      │╰╮╭╮││   │ │ ││ ││╭╮    ││╭╮╭╮ ╭╮  │││
75039769.85 ┤            ││      │ │││││   │ │ ││ ││││    ││││││ ││  │╰╯
75002180.31 ┤            ││╭╮╭──╮│ ╰╯│││╭╮ │ ╰─╯│ │╰╯│╭╮  ││││││ ││ ╭╯
74964590.77 ┤ ╭╮      ╭╮╭╯╰╯││  ╰╯   ││││╰╮│    │ │  ││╰──╯││││╰╮│╰╮│
74927001.23 ┤ ││     ╭╯╰╯   ╰╯       ╰╯╰╯ ╰╯    │ │  ││    ╰╯╰╯ ╰╯ ╰╯
74889411.69 ┤ ││     │                          ╰─╯  ╰╯
74851822.15 ┤╭╯│     │
74814232.62 ┤│ │╭╮   │
74776643.08 ┤│ ╰╯│   │
74739053.54 ┼╯   ╰───╯
```

See `Mobius.resolution` type for more information about the resolutions that
Mobius supports.

### Printing current metrics

To see the current metrics you can use `Mobius.Charts.info/0`:

```
iex> Mobius.Charts.info()
Event: vintage_net_qmi.connection.end.duration
Tags: %{ifname: "wwan0", status: :lan}
counter: 4
last_value: 310000

Event: vm.memory.total
Tags: %{}
last_value: 34674312
```

