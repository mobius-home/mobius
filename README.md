# Mobius

[![CircleCI](https://circleci.com/gh/mobius-home/mobius/tree/main.svg?style=svg)](https://circleci.com/gh/mobius-home/mobius/tree/main)

![Mobius](assets/mobius-name.png)

Library for localized telemetry metrics

## Installation

```elixir
def deps do
  [
    {:mobius, "~> 0.6.0"}
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

### Quick tips

To see a view of the current metrics you can use `Mobius.info/0`:

```elixir
iex> Mobius.info()
Metric Name: vm.memory.total
Tags: %{}
last_value: 83952736
```

To plot a metric measurement over time you can use:  `Mobius.Exports.plot/4`:

```elixir
iex> Mobius.Exports.plot("vm.memory.total", :last_value, %{})
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

### Configure persistence directory

By default Mobius will try to save metric data for all resolutions and the
current value when the erlang system exits gracefully. This makes Mobius useful
for Nerves devices that have to reboot after doing a planned firmware update.
The default direction Mobius will try to persist data to is the `/data`
directory as this is friendly to Nerves devices. If you want Mobius to store
data in a different location you can pass that into Mobius when you start it:

```elixir

children = [
   # ... other children ...
   {Mobius, metrics: metrics(), persistence_dir: "/tmp"}
   # ... other children ...
]

def metrics() do
  [
    Metrics.last_value("vm.memory.total", unit: {:byte, :kilobyte})
  ]
end
```

### Saving / Autosaving metrics data

By default the metrics data is persisted on a normal shutdown. However, data
will not be persisted during a sudden shutdown, eg Control-C in IEX, kill,
sudden power off.

It's possible to manually call Mobius.save/1 to force an interim write of the
persistence data.

This can be automated by passing `autosave_interval` to Mobius

```elixir
def start(_type, _args) do
  metrics = [
    Metrics.last_value("my.telemetry.event.measurement"),
  ]

  children = [
    # ... other children ....
    {Mobius, metrics: metrics, autosave_interval: 60} # auto save every 60 seconds
    # ... other children ....
  ]

  # See https://hexdocs.pm/elixir/Supervisor.html
  # for other strategies and supported options
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Exporting data

The `Mobius.Exports` module provide functions for exporting the data in a couple
different formats.

1. CSV
2. Series
3. Line plot
4. Mobius Binary Format

```elixir
# export as CSV string
Mobius.Exports.csv("vm.memory.total", :last_value, %{})

# export as series list
Mobius.Exports.series("vm.memory.total", :last_value, %{})

# export as mobius binary format
Mobius.Exports.mbf()
```

The Mobius Binary Format (MBF) is a binary string that has encoded and
compressed the all the historical metrics that mobius current has. This is
most useful for preparing metrics to send off to another system. To parse
the binary format you can use `Mobius.Exports.parse_mbf/1`.

For each of these you can see the `Mobius.Exports` module for more details.

### Report metrics to a remote server

Mobius allows sending metrics to a remote server. You can do this by passing the
`:remote_reporter` option to Mobius. This is a module that implements the
`Mobius.RemoteReporter` behaviour. Optionally, you can pass the
`:remote_report_interval` option to specify how often to report metrics, by
default this is every 1 minute.

### Events

In a system we want to track metrics and events. Metrics are measurements
tracked at a regular interval. These could in cloud CPU and memory usage or
something like bytes transmitted over an LTE connection. Events are things
tracked at irregular intervals that might not have a measurement. Events are
necessary to pin point moments in time that something of interest happens that
isn't necessarily a measurement. For example, firmware updates and interface
connections.

Events are good to track things that happen at particular time that are enriched
by extra data, whereas metrics are good for understand single piece of data over
time.

You can listen for raw telemetry events by passing a list of event names to
Mobius.

```elixir
def start(_type, _args) do
  events = [
    "a.button.was.pressed"
  ]

  children = [
    # ... other children ....
    {Mobius, events: events, autosave_interval: 60} # auto save every 60 seconds
    # ... other children ....
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

The above example will listen for that telemetry event and save that into
Mobius's event log.

Event configurations can take different options:

* `:tags` - list of tag names to save with the event
* `:measurement_values` - a function that will receive each measurement that
  allows for data processing before storing the event in the event log
* `:group` - an atom that defines the event group, this will allow for filtering
  on particular types of events for example: `:network`. Default is `:default`

For example if a measurement is reported in naive time and you want to convert
that to seconds you can do that this way:

```elixir
def start(_type, _args) do
  events = [
    {"a.button.was.pressed", measurement_values: &process_button_measurements/1}
  ]

  children = [
    # ... other children ....
    {Mobius, events: events, autosave_interval: 60} # auto save every 60 seconds
    # ... other children ....
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end

defp process_button_measurement({:system_time, sys_time}) do
  System.convert_time(sys_time, :naive, :second)
end

defp process_button_measurement({_, value}), do: value
```

A good resource for understanding telemetry data and some of the differences
between events and metrics is [New Relic's MELT 101 post](https://newrelic.com/platform/telemetry-data-101).

### Clocks

For systems that lack battery-backed real-time clock which will advance the
clock at startup to a reasonable guess, the early events will have a timestamp
that do not make much sense. Mobius allows you to pass the `clock` argument
which is a module that implements the `Mobius.Clock` behaviour. This behavior
has one callback: `synchronized?/0` which returns a boolean.

If a clock implementation is provide, Mobius will wait for the clock to
synchronize before including any events into the logs. Once the clock is
synchronized Mobius will make a best effort attempt to adjust early event
timestamps to reflect the actual time the event occurred and will then include
the events into the event log.

If no clock implementation is provided, Mobius will assume the clock is
synchronized and that it can trust the provided timestamps of early events.

For Nerves devices, the NervesTime package can be used:

`{Mobius, metrics: my_metrics, events: my_events, clock: NervesTime}`
