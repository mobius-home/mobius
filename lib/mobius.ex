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
  * `:day_count` - number of day-granularity samples to keep
  * `:hour_count` - number of hour-granularity samples to keep
  * `:minute_count` - number of minute-granularity samples to keep
  * `:second_count` - number of second-granularity samples to keep
  """
  @type arg() :: {:name, name()} | {:metrics, [Metrics.t()]} | {:persistence_dir, binary()}

  @typedoc """
  The name of the Mobius instance

  This is used to store data for a particular set of mobius metrics.
  """
  @type name() :: atom()

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

    args =
      args
      |> Keyword.put(:persistence_dir, mobius_persistence_path)
      |> Keyword.put_new(:day_count, 60)
      |> Keyword.put_new(:hour_count, 48)
      |> Keyword.put_new(:minute_count, 120)
      |> Keyword.put_new(:second_count, 120)

    MetricsTable.init(args)

    children = [
      {Mobius.MetricsTable.Monitor, args},
      {Mobius.Registry, args},
      {Mobius.Scraper, args}
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
