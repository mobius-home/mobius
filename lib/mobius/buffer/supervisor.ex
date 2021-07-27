defmodule Mobius.Buffer.Supervisor do
  @moduledoc false

  use Supervisor

  @typedoc """
  Arguments to the buffer supervisor

  * `:resolution` - the resolution a snapshot should run
  * `:name` - the name of the mobius instance
  """
  @type arg() :: {:resolution, Mobius.resolution()} | {:name, atom()}

  @doc """
  Start the Buffer supervisor
  """
  @spec start_link([arg()]) :: Supervisor.on_start()
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
