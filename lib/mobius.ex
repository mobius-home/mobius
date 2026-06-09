defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{Charts, Event, EventLog, MetricsTable, Plot, ReportServer, Scraper, Summary}

  alias Telemetry.Metrics

  require Logger

  @default_args [
    mobius_instance: :mobius,
    persistence_dir: "/data",
    autosave_interval: nil,
    compression_level: 9
  ]

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
  * `:compression_level` - the zlib level (`0..9`) used when compressing
     persisted metric history and event log data. Higher levels trade more CPU
     at save time for smaller files. Defaults to `9` (maximum compression). `0`
     disables compression.
  * `:database` - the `Mobius.RRD.t()` to use. This will default to the default
     values found in `Mobius.RRD`
  * `:events` - a list of events for mobius to store in the event log
  * `:event_log_size` - number of events to store (defaults to 500)
  * `:clock` - module that implements the `Mobius.Clock` behaviour
  * `:session` - a unique id to distinguish between different ties Mobius has ran

  Mobius sessions allow you collect events to analyze across the different times
  mobius ran. A good example of this might be measuring how fast an interface
  makes its first connection. You can build averages over run times and measure
  connection performance. This will allow you to know on average how fast a
  device connects so you can check for increased or decreased performance between
  runs.

  By default Mobius will generate an UUID for each run.
  """
  @type arg() ::
          {:mobius_instance, instance()}
          | {:metrics, [Metrics.t()]}
          | {:persistence_dir, binary()}
          | {:compression_level, 0..9}
          | {:database, Mobius.RRD.t()}
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

  @typedoc """
  Packed metric record used in the in-memory RRD

  This is the storage shape of a single metric inside a scrape snapshot. The
  timestamp lives one level up on the snapshot itself, so the inner tuple only
  carries identity (`name`, `tags`), `type`, and `value`.
  """
  @type metric_record() :: {metric_name(), metric_type(), term(), map()}

  @type timestamp() :: integer()

  @doc """
  Start Mobius
  """
  @spec start_link([arg()]) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, ensure_args(args), name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    Module.concat(__MODULE__.Supervisor, instance)
  end

  @impl Supervisor
  def init(args) do
    mobius_persistence_path = Path.join(args[:persistence_dir], to_string(args[:mobius_instance]))

    # An unusable persistence directory must not prevent boot — Mobius is
    # observability, not the device's purpose. Run memory-only; every save
    # attempt retries the write (and the mkdir), so persistence recovers
    # as soon as the filesystem allows it.
    case ensure_mobius_persistence_dir(mobius_persistence_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Mobius] could not create persistence directory " <>
            "#{mobius_persistence_path} (#{inspect(reason)}); starting without " <>
            "persisted history, saves will be retried"
        )
    end

    args =
      args
      |> Keyword.put_new(:session, UUID.uuid4())
      |> Keyword.update(:metrics, [], &Mobius.Events.sanitize_metrics/1)
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
        {Mobius.ReportServer, args}
      ]
      |> maybe_enable_autosave(args)

    Supervisor.init(children, strategy: :one_for_one)
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
  @spec info() :: :ok
  def info() do
    info(@default_args[:mobius_instance])
  end

  @spec info(Mobius.instance()) :: :ok
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
  @spec save() :: :ok | {:error, reason :: term()}
  def save(), do: save(@default_args[:mobius_instance])

  @spec save(instance()) :: :ok | {:error, reason :: term()}
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
  Remove all data, returning Mobius to a clean state

  This clears everything out for the instance without requiring a restart:

  * the in-memory metrics table (current counters, sums, last values, and
    summary/histogram data)
  * the accumulated historical records (the in-memory RRD)
  * the in-memory event log
  * the persisted files on disk (`history`, `metrics_table`, and
    `event_log`)

  This is useful when repurposing a device whose historical data is no
  longer meaningful, or while debugging and developing. The configured
  metrics and events keep being tracked — only the recorded data is
  discarded — so Mobius starts collecting fresh data immediately.

  If you configured Mobius to use a different name then you can pass in your
  custom name to ensure the data is removed from the right instance.
  """
  @spec remove_all_data() :: :ok
  def remove_all_data(), do: remove_all_data(@default_args[:mobius_instance])

  @spec remove_all_data(instance()) :: :ok
  def remove_all_data(instance) do
    :ok = Scraper.remove_all_data(instance)
    :ok = MetricsTable.Monitor.remove_all_data(instance)
    :ok = EventLog.clear(instance: instance)

    :ok
  end

  @doc """
  Get the latest metrics

  The latest metrics are the metrics recorded between the last query for the
  metrics and the query for the metrics that is being called.
  """
  @spec get_latest_metrics(Mobius.instance()) :: [metric()]
  def get_latest_metrics(instance \\ :mobius) do
    ReportServer.get_latest_metrics(instance)
  end

  @doc """
  Get the latest events

  The latest events are the events recorded between the last query for the
  events and the query for the events that is being called.
  """
  @spec get_latest_events(Mobius.instance()) :: [Event.t()]
  def get_latest_events(instance \\ :mobius) do
    ReportServer.get_latest_events(instance)
  end

  @doc """
  Print the metrics available to chart for an instance.

  Lists each metric's name, type, tags, and whether a histogram is available,
  so you know what to pass to `current/2` and `plot/2`.
  """
  @spec metrics(instance()) :: :ok
  def metrics(instance \\ :mobius) do
    case Charts.list_metrics(instance) do
      [] ->
        IO.puts("No metrics are being tracked for #{inspect(instance)}.")

      listing ->
        name_width = listing |> Enum.map(&String.length(&1.metric)) |> Enum.max()
        type_width = listing |> Enum.map(&(&1.type |> inspect() |> String.length())) |> Enum.max()

        IO.puts("Metrics available for #{inspect(instance)}:\n")
        Enum.each(listing, &IO.puts(format_metric_line(&1, name_width, type_width)))
    end

    :ok
  end

  defp format_metric_line(entry, name_width, type_width) do
    name = String.pad_trailing(entry.metric, name_width)
    type = entry.type |> inspect() |> String.pad_trailing(type_width)
    histogram = if entry.histogram?, do: "  (histogram)", else: ""
    tags = if entry.tags == [], do: "", else: "  tags: #{inspect(entry.tags)}"
    "  #{name}  #{type}#{histogram}#{tags}"
  end

  @doc """
  Print the current value of a metric.

  If the metric is histogram-enabled, a small ASCII histogram of its buckets is
  printed too. For tagged metrics pass `tags:` with the exact tag map.

  Options: `:type`, `:tags`, `:mobius_instance`, and the window options
  (`:last`/`:from`/`:to`) shared by `Mobius.Charts`. When `:type` is omitted it
  is inferred from the tracked metrics.
  """
  @spec current(metric_name(), keyword()) :: :ok
  def current(metric_name, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius
    tags = opts[:tags] || %{}
    query_opts = Keyword.put(opts, :mobius_instance, instance)

    case resolve_type(metric_name, opts, instance) do
      {:ok, type} ->
        print_current(metric_name, type, tags, query_opts)

      {:error, reason} ->
        IO.puts(explain(reason))
    end

    :ok
  end

  @doc """
  Print a line plot of a metric over time.

  The plot renders the series as a braille curve with a relative time x-axis.

  Options: `:type`, `:tags`, `:mobius_instance`, the window options
  (`:last`/`:from`/`:to`), and `:width`/`:height` for the plot dimensions. When
  `:type` is omitted it is inferred from the tracked metrics; summary metrics
  are not plottable directly — pass a field (e.g. `type: {:summary, :average}`)
  or use `current/2` for the histogram.

      Mobius.plot("vm.memory.total", last: {5, :minute})
  """
  @spec plot(metric_name(), keyword()) :: :ok
  def plot(metric_name, opts \\ []) do
    instance = opts[:mobius_instance] || :mobius
    tags = opts[:tags] || %{}
    query_opts = Keyword.put(opts, :mobius_instance, instance)

    with {:ok, type} <- resolve_type(metric_name, opts, instance),
         :ok <- ensure_plottable(type) do
      %{points: points} = Charts.series(metric_name, type, tags, query_opts)

      case Plot.line(points, opts) do
        {:ok, chart} ->
          IO.puts([chart_header(metric_name, type, tags), "\n\n", chart])

        {:error, message} ->
          IO.puts("#{metric_name}: #{message}")
      end
    else
      {:error, reason} -> IO.puts(explain(reason))
    end

    :ok
  end

  defp print_current(metric_name, type, tags, opts) do
    case Charts.latest([{metric_name, type, tags}], opts) do
      [%{value: value}] ->
        IO.puts([chart_header(metric_name, type, tags), " = ", format_current(value)])

      [] ->
        IO.puts([chart_header(metric_name, type, tags), ": no recent value"])
    end

    case Charts.distribution(metric_name, tags, opts) do
      {:ok, %{bins: [_ | _] = bins}} ->
        {:ok, histogram} = Plot.histogram(bins, [])
        IO.write(["\n", histogram])

      _ ->
        :ok
    end
  end

  # Use the caller's :type when given, otherwise infer it from the tracked
  # metrics. Inference fails when the name is unknown or maps to several types.
  defp resolve_type(metric_name, opts, instance) do
    case Keyword.fetch(opts, :type) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        types =
          instance
          |> Charts.list_metrics()
          |> Enum.filter(&(&1.metric == metric_name))
          |> Enum.map(& &1.type)
          |> Enum.uniq()

        case types do
          [] -> {:error, {:unknown_metric, metric_name}}
          [type] -> {:ok, type}
          many -> {:error, {:ambiguous_type, metric_name, many}}
        end
    end
  end

  defp format_current(value) when is_number(value), do: to_string(value)
  defp format_current(value), do: inspect(value)

  defp ensure_plottable(:summary), do: {:error, :summary_not_plottable}
  defp ensure_plottable(_type), do: :ok

  defp chart_header(metric_name, type, tags) do
    [
      IO.ANSI.yellow(),
      metric_name,
      IO.ANSI.reset(),
      " (#{inspect(type)})",
      tags_suffix(tags)
    ]
  end

  defp tags_suffix(tags) when tags == %{}, do: ""

  defp tags_suffix(tags) do
    [" ", IO.ANSI.cyan(), "tags: #{inspect(tags)}", IO.ANSI.reset()]
  end

  defp explain({:unknown_metric, name}),
    do: "No metric named #{inspect(name)} is being tracked. Try Mobius.metrics()."

  defp explain({:ambiguous_type, name, types}),
    do: "#{inspect(name)} has multiple types #{inspect(types)}; pass one with type:."

  defp explain(:summary_not_plottable),
    do:
      "Summary metrics are not plottable directly. Plot a field with " <>
        "type: {:summary, :average}, or use Mobius.current/2 for the histogram."
end
