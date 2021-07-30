defmodule Mobius.Buffer do
  @moduledoc false

  use GenServer

  alias Mobius.Buffer.Registry, as: BufferRegistry
  alias Mobius.Resolutions

  require Logger

  @doc """
  Start the buffer
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
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
    persistence_dir = Keyword.get(args, :persistence_dir)
    buffer = read_buffer_from_file(persistence_dir, resolution)

    Process.flag(:trap_exit, true)

    {:ok,
     %{
       buffer: buffer,
       resolution: resolution,
       persistence_dir: persistence_dir
     }}
  end

  defp read_buffer_from_file(nil, resolution) do
    resolution
    |> Resolutions.resolution_to_size()
    |> CircularBuffer.new()
  end

  defp read_buffer_from_file(persistence_dir, resolution) do
    file = buffer_file(persistence_dir, resolution)

    case File.read(file) do
      {:ok, contents} ->
        :erlang.binary_to_term(contents)

      {:error, _error} ->
        size = Resolutions.resolution_to_size(resolution)
        CircularBuffer.new(size)
    end
  end

  defp buffer_file(persistence_dir, resolution) do
    Path.join(persistence_dir, to_string(resolution))
  end

  @impl GenServer
  def handle_call({:insert, timestamp, metrics}, _from, state) do
    buffer = CircularBuffer.insert(state.buffer, {timestamp, metrics})

    {:reply, :ok, %{state | buffer: buffer}}
  end

  def handle_call(:to_list, _from, state) do
    {:reply, CircularBuffer.to_list(state.buffer), state}
  end

  @impl GenServer
  def terminate(_reason, %{persistence_dir: nil}), do: :ok

  def terminate(_reason, state) do
    file = buffer_file(state.persistence_dir, state.resolution)
    contents = :erlang.term_to_binary(state.buffer)

    case File.write(file, contents) do
      :ok ->
        :ok

      error ->
        Logger.warn(
          "Failed to save metrics buffer #{inspect(state.resolution)} because #{inspect(error)}"
        )

        error
    end
  end

  @impl GenServer
  def handle_info(_message, state) do
    {:noreply, state}
  end
end
