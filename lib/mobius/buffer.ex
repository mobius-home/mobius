defmodule Mobius.Buffer do
  @moduledoc false

  use GenServer

  alias Mobius.Buffer.Registry, as: BufferRegistry
  alias Mobius.Resolutions

  @typedoc """
  Arguments to start the buffer

  * `:resolution` - the resolution to determinate the size of the buffer
  """
  @type arg() :: {:resolution, Mobius.resolution()}

  @doc """
  Start the buffer
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    name = gen_server_opts_from_args(args)
    GenServer.start_link(__MODULE__, args, name)
  end

  defp gen_server_opts_from_args(args) do
    case args[:name] do
      nil ->
        []

      name ->
        resolution = Keyword.fetch!(args, :resolution)
        gen_server_name = BufferRegistry.via_name(name, resolution)
        [name: gen_server_name]
    end
  end

  @doc """
  Insert a metric into the buffer
  """
  @spec insert(Mobius.name() | pid(), Mobius.resolution(), DateTime.t(), [any()]) :: :ok
  def insert(name, resolution, timestamp, metrics) do
    gen_server_name = BufferRegistry.via_name(name, resolution)
    GenServer.call(gen_server_name, {:insert, timestamp, metrics})
  end

  @doc """
  Return the buffer as a list
  """
  @spec to_list(Mobius.name() | pid(), Mobius.resolution()) :: list()
  def to_list(name, resolution) do
    gen_server_name = BufferRegistry.via_name(name, resolution)
    GenServer.call(gen_server_name, :to_list)
  end

  @impl GenServer
  def init(args) do
    resolution = Keyword.fetch!(args, :resolution)
    size = Resolutions.resolution_to_size(resolution)

    {:ok, %{buffer: CircularBuffer.new(size)}}
  end

  @impl GenServer
  def handle_call({:insert, timestamp, metrics}, _from, state) do
    buffer = CircularBuffer.insert(state.buffer, {timestamp, metrics})

    {:reply, :ok, %{state | buffer: buffer}}
  end

  def handle_call(:to_list, _from, state) do
    {:reply, CircularBuffer.to_list(state.buffer), state}
  end
end
