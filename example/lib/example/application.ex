defmodule Example.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Telemetry.Metrics

  @impl true
  def start(_type, _args) do
    metrics = [
      Metrics.last_value("vm.memory.total"),
      Metrics.counter("vintage_net_qmi.connection.end.duration", tags: [:ifname, :status])
    ]

    children = [
      # Starts a worker by calling: Example.Worker.start_link(arg)
      # {Example.Worker, arg}
      {Mobius, metrics: metrics}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
