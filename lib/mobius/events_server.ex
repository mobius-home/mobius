defmodule Mobius.EventsServer do
  @moduledoc false

  use GenServer

  alias Mobius.{Event, EventLog, TimeServer}

  require Logger

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
  @spec list(Mobius.instance(), [EventLog.opt()]) :: [Event.t()]
  def list(instance \\ :mobius, opts) do
    GenServer.call(name(instance), {:list, opts})
  end

  @doc """
  Save the event log to disk
  """
  @spec save(Mobius.instance(), binary()) :: :ok
  def save(instance \\ :mobius, binary) do
    GenServer.call(name(instance), {:save, binary})
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
    Process.flag(:trap_exit, true)
    :ok = TimeServer.register(args[:mobius_instance], self())
    persistence_dir = args[:persistence_dir]
    event_log_size = args[:event_log_size] || 500

    cb = make_buffer(persistence_dir, event_log_size)
    out_of_time_buffer = make_out_of_time_buffer(args[:mobius_instance])

    {:ok,
     %{
       buffer: cb,
       persistence_dir: persistence_dir,
       size: event_log_size,
       out_of_time_buffer: out_of_time_buffer,
       instance: args[:mobius_instance]
     }}
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

  defp make_out_of_time_buffer(instance) do
    if TimeServer.synchronized?(instance) do
      nil
    else
      CircularBuffer.new(100)
    end
  end

  @impl GenServer
  def handle_call({:list, opts}, _from, state) do
    {:reply, make_list(state.buffer, opts), state}
  end

  # Synchronous so callers (and Mobius.save/1) only see :ok once the event
  # log is actually on disk — otherwise the write races a caller that reads
  # or removes the persistence dir right after save returns.
  def handle_call({:save, binary}, _from, state) do
    :ok = do_save(binary, state)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:insert_event, event}, state) do
    if TimeServer.synchronized?(state.instance) do
      new_buffer = CircularBuffer.insert(state.buffer, event)

      {:noreply, %{state | buffer: new_buffer}}
    else
      out_of_time_buffer = CircularBuffer.insert(state.out_of_time_buffer, event)
      {:noreply, %{state | out_of_time_buffer: out_of_time_buffer}}
    end
  end

  def handle_cast(:reset, state) do
    path = make_file_path(state.persistence_dir)

    _ = File.rm(path)

    {:noreply, %{state | buffer: CircularBuffer.new(state.size)}}
  end

  @impl GenServer
  def handle_info({Mobius.TimeServer, _, _}, %{out_of_time_buffer: nil} = state) do
    {:noreply, state}
  end

  def handle_info({Mobius.TimeServer, sync_timestamp, adjustment}, state) do
    out_of_time_events = CircularBuffer.to_list(state.out_of_time_buffer)
    updated = adjust_timestamps(out_of_time_events, sync_timestamp, adjustment)

    updated_buffer = insert_many(updated, state)

    {:noreply, %{state | out_of_time_buffer: nil, buffer: updated_buffer}}
  end

  defp adjust_timestamps(events, sync_timestamp, adjustment) do
    adjustment_sec = System.convert_time_unit(adjustment, :native, :second)
    sync_timestamp_sec = System.convert_time_unit(sync_timestamp, :native, :second)

    Enum.map(events, fn event ->
      # this accounts for a race condition between an event being inserted after
      # sync and before being notified that the clock synced
      if sync_timestamp_sec < event.timestamp do
        event
      else
        updated_ts = event.timestamp + adjustment_sec
        Event.set_timestamp(event, updated_ts)
      end
    end)
  end

  defp insert_many(events, state) do
    Enum.reduce(events, state.buffer, fn event, buffer ->
      CircularBuffer.insert(buffer, event)
    end)
  end

  @impl GenServer
  def terminate(_reason, state) do
    events = make_list(state.buffer, [])
    bin = EventLog.events_to_binary(events)

    do_save(bin, state)
  end

  defp make_list(buffer, opts) do
    from = opts[:from] || 0
    to = opts[:to] || System.system_time(:second)

    buffer
    |> CircularBuffer.to_list()
    |> Enum.sort_by(fn event -> event.timestamp end)
    |> Enum.filter(fn event ->
      event.timestamp >= from && event.timestamp <= to
    end)
  end

  defp make_file_path(dir) do
    Path.join(dir, @file_name)
  end

  defp do_save(binary, state) do
    # Write-to-tmp + fsync + rename so a power cut mid-write leaves the
    # previous event log intact instead of a truncated one. The persistence
    # directory may have been unavailable at boot (or gone away since), so
    # re-create it on every attempt — saving recovers as soon as the
    # filesystem allows.
    _ = File.mkdir_p(state.persistence_dir)
    path = make_file_path(state.persistence_dir)
    tmp = path <> ".tmp"

    result =
      with {:ok, fd} <- File.open(tmp, [:write, :binary]),
           :ok <- IO.binwrite(fd, binary),
           :ok <- :file.sync(fd),
           :ok <- File.close(fd) do
        File.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.warning("[Mobius]: unable to save event log: #{inspect(reason)}")
        :ok
    end
  end
end
