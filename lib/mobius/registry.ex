defmodule Mobius.Registry do
  @moduledoc false

  use GenServer

  alias Mobius.MetricsTable
  alias Telemetry.Metrics

  @typedoc """
  Arguments to start the registry server

  * `:metrics` - which metrics you want Mobius to attach a handler for
  * `:mobius_instance` - the Mobius instance
  """
  @type arg() :: {:metrics, [Metrics.t()]} | {:mobius_instance, Mobius.instance()}

  @doc """
  Start the registry server
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    args =
      args
      |> Keyword.put_new(:events, [])
      |> Keyword.put_new(:metrics, [])

    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    {:via, Registry, {Mobius.ProcessRegistry, {__MODULE__, instance}}}
  end

  @doc """
  Get which metrics Mobius is tracking
  """
  @spec metrics(Mobius.instance()) :: [Metrics.t()]
  def metrics(instance) do
    GenServer.call(name(instance), :metrics)
  end

  @impl GenServer
  def init(args) do
    # Trap exits so terminate/2 runs on shutdown and detaches our telemetry
    # handlers — otherwise they survive this process and double-count events
    # after a restart of the same instance.
    Process.flag(:trap_exit, true)

    registered = register_metrics(args) ++ register_events(args)

    {:ok,
     %{
       registered: registered,
       metrics: Keyword.fetch!(args, :metrics),
       table: args[:mobius_instance]
     }, {:continue, :update_metrics_table}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.registered, &:telemetry.detach/1)
  end

  defp register_metrics(args) do
    for {event, metrics} <- Enum.group_by(args[:metrics], & &1.event_name) do
      name = [:metric | event]
      id = {__MODULE__, name, self()}

      _ =
        :telemetry.attach(
          id,
          event,
          &Mobius.Events.handle_metrics/4,
          Mobius.Events.metric_handler_config(args[:mobius_instance], metrics)
        )

      id
    end
  end

  defp register_events(args) do
    events = args[:events] || []

    for event <- events do
      {event, event_opts} = get_event_and_opts(event)
      id = {__MODULE__, event, self()}

      _ =
        :telemetry.attach(id, event, &Mobius.Events.handle_event/4, %{
          table: args[:mobius_instance],
          event_opts: event_opts,
          session: args[:session]
        })

      id
    end
  end

  defp get_event_and_opts({event, opts}), do: {parse_event_name(event), opts}
  defp get_event_and_opts(event), do: {parse_event_name(event), []}

  defp parse_event_name(event) do
    event
    |> String.split(".", trim: true)
    |> Enum.map(&String.to_atom/1)
  end

  @impl GenServer
  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  @impl GenServer
  def handle_continue(:update_metrics_table, state) do
    metric_specs =
      Enum.map(state.metrics, &{&1.name, metric_as_type(&1), Enum.sort(&1.tags)})

    state.table
    |> MetricsTable.get_entries()
    |> Enum.each(&maybe_remove_entry(&1, metric_specs, state.table))

    {:noreply, state}
  end

  defp maybe_remove_entry({_name, {:hist, _region, _idx}, _value, _meta}, _specs, _table), do: :ok
  defp maybe_remove_entry({_name, {:hist, :zero}, _value, _meta}, _specs, _table), do: :ok

  defp maybe_remove_entry({metric_name, metric_type, _value, meta}, metric_specs, table) do
    # Entries from the table carry string names while the table itself (and
    # the configured metrics) use atom lists, so parse the name back before
    # comparing and removing.
    name = parse_event_name(metric_name)
    entry_spec = {name, metric_type, meta |> Map.keys() |> Enum.sort()}

    if !Enum.member?(metric_specs, entry_spec) do
      MetricsTable.remove(table, name, metric_type, meta)
    end
  end

  defp metric_as_type(%Metrics.Counter{}), do: :counter
  defp metric_as_type(%Metrics.LastValue{}), do: :last_value
  defp metric_as_type(%Metrics.Sum{}), do: :sum
  defp metric_as_type(%Metrics.Summary{}), do: :summary
end
