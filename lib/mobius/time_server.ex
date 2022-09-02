defmodule Mobius.TimeServer do
  @moduledoc false

  use GenServer

  @doc """
  Start the TimeServer
  """
  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    Module.concat(__MODULE__, instance)
  end

  @doc """
  Register a pid to be notified when the clock is synced
  """
  @spec register(Mobius.instance(), pid()) :: :ok
  def register(instance \\ :mobius, process) do
    GenServer.call(name(instance), {:register, process})
  end

  @doc """
  Check if the clock is synchronized
  """
  @spec synchronized?(Mobius.instance()) :: boolean()
  def synchronized?(instance \\ :mobius) do
    GenServer.call(name(instance), :synchronized?)
  end

  @impl GenServer
  def init(args) do
    started_at = System.monotonic_time()
    started_sys_time = System.system_time()
    session = args[:session]

    state = %{
      started_at: started_at,
      clock: nil,
      synced?: true,
      registered: [],
      started_sys_time: started_sys_time,
      session: session
    }

    case args[:clock] do
      nil ->
        {:ok, state}

      clock ->
        send_check_clock_after(1_000)
        {:ok, %{state | clock: clock, synced?: false}}
    end
  end

  @impl GenServer
  def handle_call({:register, pid}, _from, %{clock: nil} = state) do
    notify(System.system_time(), 0, [pid])

    {:reply, :ok, state}
  end

  def handle_call({:register, pid}, _from, state) do
    if pid in state.registered do
      {:reply, :ok, state}
    else
      registered = [pid | state.registered]

      {:reply, :ok, %{state | registered: registered}}
    end
  end

  def handle_call(:synchronized?, _from, state) do
    {:reply, state.synced?, state}
  end

  @impl GenServer
  def handle_info(:check_clock, %{synced?: false} = state) do
    if state.clock.synchronized?() do
      sync_timestamp = System.system_time()
      adjustment = sync_timestamp - state.started_sys_time

      :ok = notify(sync_timestamp, adjustment, state.registered)

      {:noreply, %{state | synced?: true}}
    else
      send_check_clock_after(1_000)

      {:noreply, state}
    end
  end

  defp notify(sync_timestamp, adjustment, registered) do
    for pid <- registered do
      send(pid, {__MODULE__, sync_timestamp, adjustment})
    end

    :ok
  end

  defp send_check_clock_after(timer) do
    Process.send_after(self(), :check_clock, timer)
  end
end
