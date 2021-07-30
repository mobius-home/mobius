defmodule Mobius.BuffersSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Mobius.Buffer.Registry, as: BufferRegistry

  @doc """
  Start the buffers supervisor
  """
  @spec start_link([Mobius.arg()]) :: Supervisor.on_start()
  def start_link(args) do
    case DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, _reg_pid} = start_registry(args)
        _ = start_buffers(args)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Start a buffer for metrics to be stored in overtime

  This will start buffers for a `table` that contains metrics. This buffer will
  have snapshots taken at a `resolution`.
  """
  @spec start_buffer_for_metrics(Mobius.resolution(), [Mobius.arg()]) ::
          Supervisor.on_start_child()
  def start_buffer_for_metrics(resolution, args) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Mobius.Buffer.Supervisor, Keyword.put(args, :resolution, resolution)}
    )
  end

  defp start_registry(args) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Registry, keys: :unique, name: BufferRegistry.name(args[:name])}
    )
  end

  @impl DynamicSupervisor
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_buffers(args) do
    resolutions = [:month, :week, :day, :hour, :minute]

    for resolution <- resolutions do
      start_buffer_for_metrics(resolution, args)
    end
  end
end
