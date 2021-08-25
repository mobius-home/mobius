defmodule Mobius.Registry do
  @moduledoc false

  use GenServer

  alias Telemetry.Metrics

  @typedoc """
  Arguments to start the registry server

  * `:metrics` - which metrics you want Mobius to attach a handler for
  * `:name` - the name used for the Mobius instance
  """
  @type arg() :: {:metrics, [Metrics.t()]} | {:name, Mobius.name()}

  @doc """
  Start the registry server
  """
  @spec start_link([arg()]) :: GenServer.on_start()
  def start_link(args) do
    ensure_metrics(args)

    GenServer.start_link(__MODULE__, args, name: gen_server_name(args[:name]))
  end

  defp gen_server_name(mobius_name) do
    Module.concat(__MODULE__, mobius_name)
  end

  defp ensure_metrics(args) do
    Keyword.get(args, :metrics) || raise "No :metrics defined in arguments to Mobius"
  end

  @doc """
  Get which metrics Mobius is tracking
  """
  @spec metrics(Mobius.name()) :: [Metrics.t()]
  def metrics(name) do
    name
    |> gen_server_name()
    |> GenServer.call(:metrics)
  end

  @impl GenServer
  def init(args) do
    registered = register_metrics(args)

    {:ok, %{registered: registered, metrics: Keyword.fetch!(args, :metrics)}}
  end

  defp register_metrics(args) do
    for {event, metrics} <- Enum.group_by(args[:metrics], & &1.event_name) do
      id = {__MODULE__, event, self()}

      _ =
        :telemetry.attach(id, event, &Mobius.Events.handle/4, %{
          table: args[:name],
          metrics: metrics
        })

      id
    end
  end

  @impl GenServer
  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end
end
