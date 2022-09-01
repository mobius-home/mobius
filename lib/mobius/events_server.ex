defmodule Mobius.EventsServer do
  @moduledoc false

  use GenServer

  require Logger

  alias Mobius.{Event, EventLog}

  @file_name "event_log"

  @doc """
  Start the event log server
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    instance = args[:mobius_instance] || :mobius
    GenServer.start_link(__MODULE__, args, name: name(instance))
  end

  defp name(instance) do
    Module.concat(__MODULE__, instance)
  end

  @doc """
  Insert an event
  """
  @spec insert(Mobius.instance(), Event.t()) :: :ok
  def insert(instance \\ :mobius, event) do
    GenServer.cast(name(instance), {:insert_event, event})
  end

  @doc """
  List the events
  """
  @spec list(Mobius.instance()) :: [Event.t()]
  def list(instance \\ :mobius) do
    GenServer.call(name(instance), :list)
  end

  @doc """
  Save the event log to disk
  """
  @spec save(Mobius.instance(), binary()) :: :ok
  def save(instance \\ :mobius, binary) do
    GenServer.cast(name(instance), {:save, binary})
  end

  @doc """
  Clear the event log and stored data
  """
  @spec clear(Mobius.instance()) :: :ok
  def clear(instance \\ :mobius) do
    GenServer.cast(name(instance), :reset)
  end

  @impl GenServer
  def init(args) do
    persistence_dir = args[:persistence_dir]
    event_log_size = args[:event_log_size] || 1000

    cb = make_buffer(persistence_dir, event_log_size)

    {:ok, %{buffer: cb, persistence_dir: persistence_dir, size: event_log_size}}
  end

  defp make_buffer(persistence_dir, log_size) do
    path = make_file_path(persistence_dir)

    with {:ok, binary} <- File.read(path),
         {:ok, event_log_list} <- EventLog.parse(binary) do
      buffer = CircularBuffer.new(log_size)

      Enum.reduce(event_log_list, buffer, fn event, buff ->
        CircularBuffer.insert(buff, event)
      end)
    else
      _ ->
        CircularBuffer.new(log_size)
    end
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, make_list(state.buffer), state}
  end

  @impl GenServer
  def handle_cast({:insert_event, event}, state) do
    new_buffer = CircularBuffer.insert(state.buffer, event)

    {:noreply, %{state | buffer: new_buffer}}
  end

  def handle_cast({:save, binary}, state) do
    path = make_file_path(state.persistence_dir)

    case File.write(path, binary) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warn("[Mobius]: unable to save event log: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast(:reset, state) do
    path = make_file_path(state.persistence_dir)

    _ = File.rm(path)

    {:noreply, %{state | buffer: CircularBuffer.new(state.size)}}
  end

  defp make_list(buffer) do
    buffer
    |> CircularBuffer.to_list()
    |> Enum.sort_by(fn event -> event.timestamp end)
  end

  defp make_file_path(dir) do
    Path.join(dir, @file_name)
  end
end
