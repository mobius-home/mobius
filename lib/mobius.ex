defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.MetricsTable

  alias Telemetry.Metrics

  @default_args [name: :mobius_metrics]

  @typedoc """
  Arguments to Mobius

  * `:name` - the name of the mobius instance (defaults to `:mobius_metrics`)
  * `:metrics` - list of telemetry metrics for Mobius to track
  """
  @type arg() :: {:name, name()} | {:metrics, [Metrics.t()]}

  @typedoc """
  The name of the Mobius instance

  This is used to store data for a particular set of mobius metrics.
  """
  @type name() :: atom()

  @typedoc """
  The time resolution of the metrics being collected

  * `:month` - metrics over the last 31 days
  * `:week` - metrics over the last 7 days
  * `:day` - metrics over the last 24 hours
  * `:hour` - metrics over the last 60 minutes
  * `:minute` - metrics over the last 60 seconds
  """
  @type resolution() :: :month | :week | :day | :hour | :minute

  @type metric_type() :: :counter | :last_value

  @type metric_name() :: [atom()]

  @doc """
  args: metrics, name
  """
  def start_link(args) do
    Supervisor.start_link(__MODULE__, ensure_args(args), name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(args) do
    MetricsTable.init(args[:name])

    children = [
      {Mobius.Registry, args},
      {Mobius.BuffersSupervisor, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ensure_args(args) do
    Keyword.merge(@default_args, args)
  end
end
