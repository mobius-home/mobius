defmodule Mobius.Buffer.Supervisor do
  @moduledoc false

  use Supervisor

  @doc """
  Start the Buffer supervisor
  """
  @spec start_link([Mobius.arg()]) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  @impl Supervisor
  def init(args) do
    children = [
      {Mobius.Buffer, args},
      {Mobius.Buffer.Snapshot, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
