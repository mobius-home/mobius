defmodule Mobius.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Mobius.ProcessRegistry}
    ]

    opts = [strategy: :one_for_one, name: Mobius.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
