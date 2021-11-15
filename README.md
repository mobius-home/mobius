# Mobius

[![CircleCI](https://circleci.com/gh/mattludwigs/mobius/tree/main.svg?style=svg)](https://circleci.com/gh/mattludwigs/mobius/tree/main)

Library for localized telemetry metrics

## Installation

```elixir
def deps do
  [
    {:mobius, "~> 0.3.4"}
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

```elixir
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

### Printing current metrics

To see the current metrics you can use `Mobius.info/0`:

```elixir
iex> Mobius.info()

Metric Name: vintage_net_qmi.connection.end.duration
Tags: %{ifname: "wwan0", status: :disconnected}
sum: 1247
last_value: 0

Metric Name: vintage_net_qmi.connection.end.duration
Tags: %{ifname: "wwan0", status: :internet}
sum: 667037
last_value: 0

Metric Name: vintage_net_qmi.connection.statistics.rx_bytes
Tags: %{ifname: "wwan0"}
last_value: 1829748

Metric Name: vintage_net_qmi.connection.statistics.rx_errors
Tags: %{ifname: "wwan0"}
last_value: 0

Metric Name: vintage_net_qmi.connection.statistics.rx_packets
Tags: %{ifname: "wwan0"}
last_value: 36125

Metric Name: vintage_net_qmi.connection.statistics.tx_bytes
Tags: %{ifname: "wwan0"}
last_value: 3113540

Metric Name: vintage_net_qmi.connection.statistics.tx_errors
Tags: %{ifname: "wwan0"}
last_value: 0

Metric Name: vintage_net_qmi.connection.statistics.tx_packets
Tags: %{ifname: "wwan0"}
last_value: 61417

Metric Name: vintage_net_qmi.connection.status
Tags: %{ifname: "wwan0"}
last_value: 0

Metric Name: vintage_net_qmi.connection.status
Tags: %{ifname: "wwan0", status: :disconnected}
counter: 897

Metric Name: vintage_net_qmi.connection.status
Tags: %{ifname: "wwan0", status: :internet}
counter: 68

Metric Name: vintage_net_qmi.signal_strength.asu
Tags: %{ifname: "wwan0"}
last_value: 99

Metric Name: vintage_net_qmi.signal_strength.bars
Tags: %{ifname: "wwan0"}
last_value: 1

Metric Name: vintage_net_qmi.signal_strength.dbm
Tags: %{ifname: "wwan0"}
last_value: -128

Metric Name: vintage_net_qmi.signal_strength.rssi
Tags: %{ifname: "wwan0"}
last_value: -128

Metric Name: vm.memory.total
Tags: %{}
last_value: 83952736
```
