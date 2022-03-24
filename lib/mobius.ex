defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{Bundle, MetricsTable, Scraper, Summary}

  alias Telemetry.Metrics

  @default_args [mobius_instance: :mobius, persistence_dir: "/data", autosave_interval: nil]

  @type time_unit() :: :second | :minute | :hour | :day

  @typedoc """
  Arguments to Mobius

  * `:name` - the name of the mobius instance (defaults to `:mobius`)
  * `:metrics` - list of telemetry metrics for Mobius to track
  * `:persistence_dir` - the top level directory where mobius will persist
  * `:autosave_interval` - time in seconds between automatic writes of the
     persistence data (default disabled) metric information
  * `:database` - the `Mobius.RRD.t()` to use. This will default to the the default
     values found in `Mobius.RRD`
  """
  @type arg() ::
          {:mobius_instance, instance()}
          | {:metrics, [Metrics.t()]}
          | {:persistence_dir, binary()}
          | {:database, Mobius.RRD.t()}

  @typedoc """
  The name of the Mobius instance

  This is used to store data for a particular set of mobius metrics.
  """
  @type instance() :: atom()

  @type metric_type() :: :counter | :last_value | :sum | :summary

  @typedoc """
  The name of the metric

  Example: `"vm.memory.total"`
  """
  @type metric_name() :: binary()

  @typedoc """
  A single metric data point

  * `:type` - the type of the metric
  * `:value` - the value of the measurement for the metric
  * `:tags` - a map of the tags for the metric
  * `:timestamp` - the naive time in seconds the metric was sampled
  * `:name` - the name of the metric
  """
  @type metric() :: %{
          type: metric_type(),
          value: term(),
          tags: map(),
          timestamp: integer(),
          name: binary()
        }

  @type timestamp() :: integer()

  @typedoc """
  A list of data recorded data points tied to a particular timestamp
  """
  @type record() ::
          {timestamp(),
           [
             {:telemetry.event_name(), Mobius.metric_type(), :telemetry.event_value(),
              :telemetry.event_metadata()}
           ]}

  @doc """
  Start Mobius
  """
  def start_link(args) do
    Supervisor.start_link(__MODULE__, ensure_args(args), name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(args) do
    mobius_persistence_path = Path.join(args[:persistence_dir], to_string(args[:mobius_instance]))

    case ensure_mobius_persistence_dir(mobius_persistence_path) do
      :ok ->
        args =
          args
          |> Keyword.put(:persistence_dir, mobius_persistence_path)
          |> Keyword.put_new(:database, Mobius.RRD.new())

        MetricsTable.init(args)

        children =
          [
            {Mobius.MetricsTable.Monitor, args},
            {Mobius.Registry, args},
            {Mobius.Scraper, args}
          ]
          |> maybe_enable_autosave(args)

        Supervisor.init(children, strategy: :one_for_one)

      {:error, :enoent} ->
        raise("persistence_path does not exist: #{mobius_persistence_path}")

      {:error, msg} ->
        raise("could not start mobius: #{msg}")
    end
  end

  defp ensure_args(args) do
    Keyword.merge(@default_args, args)
  end

  defp ensure_mobius_persistence_dir(persistence_path) do
    case File.mkdir_p(persistence_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      error ->
        error
    end
  end

  defp maybe_enable_autosave(children, args) do
    if is_number(args[:autosave_interval]) and args[:autosave_interval] > 0 do
      children ++ [{Mobius.AutoSave, args}]
    else
      children
    end
  end

  @doc """
  Get the current metric information

  If you configured Mobius to use a different name then you can pass in your
  custom name to ensure Mobius requests the metrics from the right place.
  """
  @spec info(Mobius.instance() | nil) :: :ok
  def info() do
    info(@default_args[:mobius_instance])
  end

  def info(instance) do
    instance
    |> MetricsTable.get_entries()
    |> Enum.group_by(fn {metric_name, _type, _value, meta} -> {metric_name, meta} end)
    |> Enum.each(fn {{metric_name, meta}, metrics} ->
      reports =
        Enum.map(metrics, fn {_metric_name, type, value, _meta} ->
          "#{to_string(type)}: #{inspect(format_value(type, value))}\n"
        end)

      [
        "Metric Name: ",
        metric_name,
        "\n",
        "Tags: #{inspect(meta)}\n",
        reports
      ]
      |> IO.puts()
    end)
  end

  defp format_value(:summary, summary_data) do
    Summary.calculate(summary_data)
  end

  defp format_value(_, value) do
    value
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(instance()) :: :ok | {:error, reason :: term()}
  def save(), do: save(@default_args[:mobius_instance])

  def save(instance) do
    start_t = System.monotonic_time()
    prefix = [:mobius, :save]

    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, %{
      instance: instance
    })

    with :ok <- Scraper.save(instance),
         :ok <- MetricsTable.Monitor.save(instance) do
      duration = System.monotonic_time() - start_t
      :telemetry.execute(prefix ++ [:stop], %{duration: duration}, %{instance: instance})

      :ok
    else
      error ->
        duration = System.monotonic_time() - start_t

        :telemetry.execute(
          prefix ++ [:exception],
          %{reason: inspect(error), duration: duration},
          %{instance: instance}
        )

        error
    end
  end

  @type make_bundle_opt() :: {:mobius_instance, instance()}

  @doc """
  Function for creating a `Mobius.Bundle.t()`

  This function makes a bundle that can be used with the functions in
  `Mobius.Bundle`
  """
  @spec make_bundle(Bundle.target(), [make_bundle_opt()]) :: Bundle.t()
  def make_bundle(bundle_target, opts \\ []) do
    mobius_name = opts[:mobius_instance] || @default_args[:mobius_instance]
    data = Scraper.all(mobius_name)

    Bundle.new(bundle_target, data)
  end
end
