defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.MetricsTable

  alias Telemetry.Metrics

  @default_args [name: :mobius, persistence_dir: "/data"]

  @typedoc """
  Arguments to Mobius

  * `:name` - the name of the mobius instance (defaults to `:mobius`)
  * `:metrics` - list of telemetry metrics for Mobius to track
  * `:persistence_dir` - the top level directory where mobius will persist
    metric information
  """
  @type arg() :: {:name, name()} | {:metrics, [Metrics.t()]} | {:persistence_dir, binary()}

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
  Start Mobius
  """
  def start_link(args) do
    Supervisor.start_link(__MODULE__, ensure_args(args), name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(args) do
    mobius_persistence_path = Path.join(args[:persistence_dir], to_string(args[:name]))
    :ok = ensure_mobius_persistence_dir(mobius_persistence_path)
    args = Keyword.put(args, :persistence_dir, mobius_persistence_path)

    MetricsTable.init(args)

    children = [
      {Mobius.MetricsTable.Monitor, args},
      {Mobius.Registry, args},
      {Mobius.BuffersSupervisor, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ensure_args(args) do
    Keyword.merge(@default_args, args)
  end

  defp ensure_mobius_persistence_dir(persistence_path) do
    case File.mkdir(persistence_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      error ->
        error
    end
  end
end
