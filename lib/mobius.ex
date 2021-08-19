defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{MetricsTable, Scraper}

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

  @typedoc """
  Options to use when plotting time series metric data

  * `:name` - the name of the Mobius instance you are using. Unless you
    specified this in your configuration you should be safe to allow this
    option to default, which is `:mobius_metrics`.
  """
  @type plot_opt() :: {:name, Mobius.name()}

  @doc """
  Plot the metric name to the screen

  If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.Charts.plot("vm.memory.total", %{some: :tag})
  ```
  """
  @spec plot(binary(), map(), [plot_opt()]) :: :ok
  def plot(metric_name, tags \\ %{}, opts \\ []) do
    parsed_metric_name = parse_metric_name(metric_name)

    series =
      opts
      |> Keyword.get(:name, :mobius)
      |> Scraper.all()
      |> Enum.flat_map(fn {_timestamp, metrics} ->
        series_for_metric_from_metrics(metrics, parsed_metric_name, tags)
      end)

    {:ok, plot} = Mobius.Asciichart.plot(series, height: 12)

    chart = [
      "\t\t",
      IO.ANSI.yellow(),
      "Metric Name: ",
      metric_name,
      IO.ANSI.reset(),
      ", ",
      IO.ANSI.cyan(),
      "Tags: #{inspect(tags)}",
      IO.ANSI.reset(),
      "\n\n",
      plot
    ]

    IO.puts(chart)
  end

  defp series_for_metric_from_metrics(metrics, metric_name, tags) do
    Enum.reduce(metrics, [], fn
      {^metric_name, _type, value, ^tags}, ms ->
        ms ++ [value]

      _, ms ->
        ms
    end)
  end

  defp parse_metric_name(metric_name),
    do: metric_name |> String.split(".", trim: true) |> Enum.map(&String.to_existing_atom/1)

  @doc """
  Get the current metric information

  If you configured Mobius to use a different name then you can pass in your
  custom name to ensure Mobius requests the metrics from the right place.
  """
  @spec info(Mobius.name() | nil) :: :ok
  def info(name \\ nil) do
    name = name || :mobius

    name
    |> MetricsTable.get_entries()
    |> Enum.group_by(fn {event_name, _type, _value, meta} -> {event_name, meta} end)
    |> Enum.each(fn {{event_name, meta}, metrics} ->
      reports =
        Enum.map(metrics, fn {_event_name, type, value, _meta} ->
          "#{to_string(type)}: #{inspect(value)}\n"
        end)

      [
        "Metric Name: ",
        Enum.join(event_name, "."),
        "\n",
        "Tags: #{inspect(meta)}\n",
        reports
      ]
      |> IO.puts()
    end)
  end
end
