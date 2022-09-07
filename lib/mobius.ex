defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{EventLog, MetricsTable, RemoteReporter, ReportingServer, Scraper, Summary}

  alias Telemetry.Metrics

  @default_args [mobius_instance: :mobius, persistence_dir: "/data", autosave_interval: nil]

  @type time_unit() :: :second | :minute | :hour | :day

  @typedoc """
  A function to process an event's measurements

  This will be called on each measurement and will receive a tuple where the
  first element is the name of the measurement and the second element is the
  value. This function can process the value and return a new one.
  """
  @type event_measurement_values() :: ({atom(), term()} -> term())

  @typedoc """
  Options you can pass an event

  These options only apply to the `:event` argument to Mobius. If you want
  to track metrics please see the `:metrics` argument to Mobius.

  * `:tags` - list of tag names to save with the event
  * `:measurement_values` - a function that will receive each measurement that
    allows for data processing before storing the event in the event log
  * `:group` - an atom that defines the event group, this will allow for filtering
    on particular types of events for example: `:network`. Default is `:default`
  """
  @type event_opt() ::
          {:measurement_values, event_measurement_values()} | {:tags, [atom()]} | {:group, atom()}

  @type event_def() :: [binary() | {binary(), keyword()}]

  @typedoc """
  Arguments to Mobius

  * `:name` - the name of the mobius instance (defaults to `:mobius`)
  * `:metrics` - list of telemetry metrics for Mobius to track
  * `:persistence_dir` - the top level directory where mobius will persist
  * `:autosave_interval` - time in seconds between automatic writes of the
     persistence data (default disabled) metric information
  * `:database` - the `Mobius.RRD.t()` to use. This will default to the the default
     values found in `Mobius.RRD`
  * `:remote_reporter` - module that implements the `Mobius.RemoteReporter`
    behaviour. If this not configured triggering a report will not work.
  * `:remote_report_interval` - if you want Mobius to trigger sending metrics at
    an interval you can provide an interval in milliseconds. If this is not
    configured you can trigger a metric report by calling
    `Mobius.RemoteReporter.report_metrics/1`.
  * `:events` - a list of events for mobius to store in the event log
  * `:event_log_size` - number of events to store (defaults to 500)
  * `:clock` - module that implements the `Mobius.Clock` behaviour
  * `:session` - a unique id to distinguish between different ties Mobius has ran

  Mobius sessions allow you collect events to analyze across different different
  times mobius ran. A good example of this might measuring how fast an interface
  makes its first connection. You can build averages over run times and measure
  connection performance. This will allow you to know on average how fast a
  device connects and can check for increased or decreased performance between
  runs.

  By default Mobius will generate an UUID for each run.
  """
  @type arg() ::
          {:mobius_instance, instance()}
          | {:metrics, [Metrics.t()]}
          | {:persistence_dir, binary()}
          | {:database, Mobius.RRD.t()}
          | {:remote_reporter, RemoteReporter.t() | {RemoteReporter.t(), term()}}
          | {:remote_report_interval, non_neg_integer()}
          | {:events, [event_def()]}
          | {:event_log_size, integer()}
          | {:clock, module()}
          | {:session, session()}

  @typedoc """
  The name of the Mobius instance

  This is used to store data for a particular set of mobius metrics.
  """
  @type instance() :: atom()

  @type metric_type() :: :counter | :last_value | :sum | :summary

  @type session() :: binary()

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

  @doc """
  Start Mobius
  """
  def start_link(args) do
    Supervisor.start_link(__MODULE__, ensure_args(args), name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    Module.concat(__MODULE__.Supervisor, instance)
  end

  @impl Supervisor
  def init(args) do
    mobius_persistence_path = Path.join(args[:persistence_dir], to_string(args[:mobius_instance]))
    args = Keyword.put_new(args, :session, UUID.uuid4())

    case ensure_mobius_persistence_dir(mobius_persistence_path) do
      :ok ->
        args =
          args
          |> Keyword.put(:persistence_dir, mobius_persistence_path)
          |> Keyword.put_new(:database, Mobius.RRD.new())

        MetricsTable.init(args)

        children =
          [
            {Mobius.TimeServer, args},
            {Mobius.MetricsTable.Monitor, args},
            {Mobius.EventsServer, args},
            {Mobius.Registry, args},
            {Mobius.Scraper, args},
            {ReportingServer, make_reporting_server_args(args)}
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

  defp make_reporting_server_args(mobius_args) do
    reporter = Keyword.get(mobius_args, :remote_reporter)
    report_interval = mobius_args[:remote_report_interval]

    [
      reporter: reporter,
      report_interval: report_interval,
      mobius_instance: mobius_args[:mobius_instance]
    ]
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
         :ok <- MetricsTable.Monitor.save(instance),
         :ok <- EventLog.save(instance: instance) do
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

  @doc """
  Get the latest metrics

  This will query Mobius to get the metrics from the last time metrics were
  queried. This function is useful for when you want other software to control
  how reports are built, but you don't need to have the reports built and sent
  at an interval.
  """
  @spec get_latest_metrics(Mobius.instance()) :: [metric()]
  def get_latest_metrics(mobius_instance \\ :mobius) do
    ReportingServer.get_latest_metrics(mobius_instance)
  end
end
