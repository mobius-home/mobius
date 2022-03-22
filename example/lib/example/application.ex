defmodule Example.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Telemetry.Metrics

  @impl true
  def start(_type, _args) do
    metrics = [
      Metrics.counter("example.inc.count", tags: [:ifname]),
      Metrics.last_value("example.inc.duration", tags: [:ifname]),
      Metrics.last_value("vm.memory.total"),
      Metrics.summary("vm.memory.total")
    ]

    # custom database that tracks seconds resolution for 5 minutes
    database = Mobius.RRD.new(seconds: 300)

    children = [
      # Starts a worker by calling: Example.Worker.start_link(arg)
      # {Example.Worker, arg}
      {Mobius, metrics: metrics, persistence_dir: "/tmp", database: database}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
