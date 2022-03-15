defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{Bundle, MetricsTable, Scraper, Summary}

  alias Telemetry.Metrics

  @default_args [name: :mobius, persistence_dir: "/data", autosave_interval: nil]

  @type time_unit() :: :second | :minute | :hour | :day

  @typedoc """
  Arguments to Mobius

  * `:name` - the name of the mobius instance (defaults to `:mobius`)
  * `:metrics` - list of telemetry metrics for Mobius to track
  * `:persistence_dir` - the top level directory where mobius will persist
  * `:autosave_interval` - time in seconds between automatic writes of the persistence data (default disabled)
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

  @type metric_type() :: :counter | :last_value | :sum | :summary

  @type metric_name() :: [atom()]

  @typedoc """
  Options to use when filtering time series metric data

  * `:name` - the name of the Mobius instance you are using. Unless you
    specified this in your configuration you should be safe to allow this
    option to default, which is `:mobius_metrics`.
  * `:last` - display data point that have been captured over the last `x`
    amount of time. Where `x` is either an integer or a tuple of
    `{integer(), time_unit()}`. If you only pass an integer the time unit of
    `:seconds` is assumed. By default Mobius will plot the last 3 minutes of
    data.
  * `:from` - the unix timestamp, in seconds, to start querying from
  * `:to` - the unix timestamp, in seconds, to stop querying at
  * `:type` - for metrics that have different types of measurements, you can pass
    this option to filter which metric type you want to plot
  """
  @type filter_opt() ::
          {:name, Mobius.name()}
          | {:last, integer() | {integer(), time_unit()}}
          | {:from, integer()}
          | {:to, integer()}
          | {:type, metric_type()}

  @typedoc """
  Options for our plot export
  """
  @type plot_opt() :: filter_opt()

  @type naming_opt :: :csv_ext | :timestamp

  @typedoc """
  Options for our CSV export
  """
  @type csv_opt() ::
          {:file, String.t()}
          | {:naming, [naming_opt]}
          | filter_opt()

  @type metric() :: %{type: metric_type(), value: term(), tags: map(), timestamp: integer()}
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
    mobius_persistence_path = Path.join(args[:persistence_dir], to_string(args[:name]))

    case ensure_mobius_persistence_dir(mobius_persistence_path) do
      :ok ->
        args =
          args
          |> Keyword.put(:persistence_dir, mobius_persistence_path)
          |> Keyword.put_new(:day_count, 60)
          |> Keyword.put_new(:hour_count, 48)
          |> Keyword.put_new(:minute_count, 120)
          |> Keyword.put_new(:second_count, 120)

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
  Retrieve the raw metric data from the history store for a given metric.

  Output will be a list of metric values, which will be in the format, eg:
    %{type: :last_value, value: 12, tags: %{interface: "eth0"}, timestamp: 1645107424}

    If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.filter_metrics("vm.memory.total", %{some: :tag})
  ```

  By default the filter will display the last 3 minutes of metric history.

  However, you can pass the `:from` and `:to` options to look at a specific
  range of time.

  ```elixir
  Mobius.filter_metrics("vm.memory.total", %{}, from: 1630619212, to: 1630619219)
  ```

  You can also filter data over the last `x` amount of time. Where x is an
  integer. When there is no `time_unit()` provided the unit is assumed to be
  `:second`.

  Retrieving data over the last 30 seconds:

  ```elixir
  Mobius.filter_metrics("vm.memory.total", %{}, last: 30)
  ```

  Retrieving data over the last 2 hours:

  ```elixir
  Mobius.filter_metrics("vm.memory.total", %{}, last: {2, :hour})
  ```
  """
  @spec filter_metrics(String.t(), map, [filter_opt()]) :: [metric()]
  def filter_metrics(metric_name, tags \\ %{}, opts \\ []) do
    start_t = System.monotonic_time()
    prefix = [:mobius, :filter]

    name = Keyword.get(opts, :name, :mobius)
    parsed_metric_name = parse_metric_name(metric_name)
    scraper_opts = query_opts(opts)

    # Notify telemetry we are starting query
    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, %{
      name: name,
      metric_name: metric_name,
      tags: tags,
      opts: scraper_opts
    })

    rows =
      Scraper.all(name, scraper_opts)
      |> Enum.flat_map(fn {timestamp, metrics} ->
        rows_from_metrics(metrics, parsed_metric_name, tags, timestamp, opts)
      end)

    # Notify telemetry we finished query
    duration = System.monotonic_time() - start_t

    :telemetry.execute(prefix ++ [:stop], %{duration: duration}, %{
      name: name,
      metric_name: metric_name,
      tags: tags,
      opts: scraper_opts
    })

    rows
  end

  @doc """
  Plot the metric name to the screen

  This takes the same arguments as for filter_metrics, eg:

  If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.plot("vm.memory.total", %{some: :tag})
  ```

  By default the plot will display the last 3 minutes of metric history.

  However, you can pass the `:from` and `:to` options to look at a specific
  range of time.

  ```elixir
  Mobius.plot("vm.memory.total", %{}, from: 1630619212, to: 1630619219)
  ```

  You can also plot data over the last `x` amount of time. Where x is an
  integer. When there is no `time_unit()` provided the unit is assumed to be
  `:second`.

  Plotting data over the last 30 seconds:

  ```elixir
  Mobius.plot("vm.memory.total", %{}, last: 30)
  ```

  Plotting data over the last 2 hours:

  ```elixir
  Mobius.plot("vm.memory.total", %{}, last: {2, :hour})
  ```
  """
  @spec plot(binary(), map(), [plot_opt()]) :: :ok
  def plot(metric_name, tags \\ %{}, opts \\ []) do
    series =
      filter_metrics(metric_name, tags, opts)
      |> Enum.flat_map(fn
        %{value: value} when value != nil -> [value]
        _ -> []
      end)

    case Mobius.Asciichart.plot(series, height: 12) do
      {:ok, plot} ->
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

      {:error, _} = error ->
        error
    end
  end

  def query_opts(opts) do
    if opts[:from] do
      Keyword.take(opts, [:from, :to])
    else
      last_ts(opts)
    end
  end

  def last_ts(opts) do
    now = System.system_time(:second)

    ts =
      case opts[:last] do
        nil ->
          now - 180

        {offset, unit} ->
          now - offset * get_unit_offset(unit)

        offset ->
          now - offset
      end

    [from: ts]
  end

  defp get_unit_offset(:second), do: 1
  defp get_unit_offset(:minute), do: 60
  defp get_unit_offset(:hour), do: 3600
  defp get_unit_offset(:day), do: 86400

  @doc """
  Produces a CSV of currently collected metrics, optionally writing the CSV to file.
  The CSV looks like: timestamp, name, type, value, tag1, tag2, tag3..., tagN
  If tags are provided, only the metrics matching the tags are output to the CSV.
  If a writable file is given via the :file option, the CSV is written to it. Otherwise it is written to the terminal.
  If the optional :naming option contains :csv_ext, the .csv extension is added to the file name if not already present.
  If the optional :naming option list :timestamp, the file name is prefixed by a timestamp.

  This accepts the same arguments as for filter_metrics to control the metrics, tags, times, etc
  to be outputted to CSV:

   * `:last` - metrics captured over the last `x`
    amount of time. Where `x` is either an integer or a tuple of
    `{integer(), time_unit()}`. If you only pass an integer the time unit of
    `:seconds` is assumed. By default the last 3 minutes of
    data will be outputted.
  * `:from` - the unix timestamp, in seconds, to start querying from
  * `:to` - the unix timestamp, in seconds, to stop querying at

  If a metric has multiple types, a CSV can filter on one type with option `type: :sum` or `type: :last_value` etc..

  Examples:

  iex> Mobius.to_csv("vm.memory.total", %{})
  # -- writes CSV values to the terminal

  iex> Mobius.to_csv("vm.memory.total", %{}, file: "/data/csv/vm.memory.total")
  # -- writes CSV values to file vm.memory.total

  iex> Mobius.to_csv("vm.memory.total", %{}, file: "/data/csv/vm.memory.total", naming: [:csv_ext, :timestamp])
  # -- writes CSV values to a file like 20210830T174954_vm.memory.total.csv

  iex> Mobius.to_csv("vm.memory.total", %{})
  # -- writes CSV values to the terminal

  iex> Mobius.to_csv("vintage_net_qmi.connection.end.duration", %{ifname: "wwan0", status: :disconnected}, type: :sum, last: {60, :day})
  # -- writes CSV values to the terminal

  """
  @spec to_csv(String.t(), map, [csv_opt]) :: :ok
  def to_csv(metric_name, tags \\ %{}, opts \\ []) do
    rows = filter_metrics(metric_name, tags, opts)
    tag_names = unique_tag_names(rows)

    headers_row =
      ["timestamp", "name", "type", "value"] ++
        for tag_name <- tag_names, do: Atom.to_string(tag_name)

    data_rows = format_metrics_as_csv(rows, metric_name, tag_names)

    csv([headers_row | data_rows], opts)
  end

  defp unique_tag_names(rows) do
    Enum.reduce(rows, MapSet.new(), fn row, set ->
      Enum.reduce(Map.keys(row.tags), set, fn tag_name, acc -> MapSet.put(acc, tag_name) end)
    end)
    |> Enum.sort()
  end

  defp format_metrics_as_csv(rows, metric_name, tag_names) do
    rows
    |> Enum.map(fn row ->
      tag_values = for tag_name <- tag_names, do: "#{Map.get(row.tags, tag_name, "")}"

      data_row =
        [
          "#{row.timestamp}",
          "#{metric_name}",
          "#{row.type}",
          "#{inspect(format_value(row.type, row.value))}"
        ] ++
          tag_values

      data_row
    end)
  end

  defp csv(all_rows, opts) do
    filepath = csv_file(opts)

    out =
      if filepath do
        with :ok <- File.mkdir_p(Path.dirname(filepath)),
             {:ok, device} <- File.open(filepath, [:write]) do
          device
        else
          {:error, reason} ->
            IO.puts(
              "Failed to open file #{inspect(filepath)} to write CSV: #{inspect(reason)}. Writing to terminal instead."
            )

            :stdio
        end
      else
        :stdio
      end

    Enum.each(all_rows, fn row -> IO.write(out, [Enum.intersperse(row, ","), "\n"]) end)
    :ok
  end

  defp csv_file(opts) do
    case Keyword.get(opts, :file) do
      path when is_binary(path) ->
        dir = Path.dirname(path)

        file =
          path
          |> Path.split()
          |> List.last()
          |> maybe_with_csv_ext(opts)
          |> maybe_with_timestamp(opts)

        final_path = Path.join(dir, file)
        IO.puts("[Mobius] Writing CSV to #{final_path}")
        final_path

      _ ->
        nil
    end
  end

  defp maybe_with_csv_ext(path, opts) do
    add_csv_ext? = :csv_ext in Keyword.get(opts, :naming, [])

    if add_csv_ext? and not String.ends_with?(path, ".csv") do
      path <> ".csv"
    else
      path
    end
  end

  defp maybe_with_timestamp(path, opts) do
    if :timestamp in Keyword.get(opts, :naming, []) do
      [ts | _] = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.split(".")
      ts <> "_" <> path
    else
      path
    end
  end

  defp rows_from_metrics(metrics, metric_name, tags, timestamp, opts) do
    required_type = Keyword.get(opts, :type)

    metrics
    |> Enum.flat_map(fn
      {^metric_name, type, value, metric_tags} ->
        if match?(^tags, metric_tags) and matches_type?(type, required_type) do
          [%{type: type, value: value, tags: metric_tags, timestamp: timestamp}]
        else
          []
        end

      _metric ->
        []
    end)
  end

  defp matches_type?(_type, nil), do: true

  defp matches_type?(type, type), do: true
  defp matches_type?(_, _), do: false

  defp parse_metric_name(metric_name),
    do: metric_name |> String.split(".", trim: true) |> Enum.map(&String.to_existing_atom/1)

  @doc """
  Get the current metric information

  If you configured Mobius to use a different name then you can pass in your
  custom name to ensure Mobius requests the metrics from the right place.
  """
  @spec info(Mobius.name() | nil) :: :ok
  def info(name \\ @default_args[:name]) do
    name
    |> MetricsTable.get_entries()
    |> Enum.group_by(fn {event_name, _type, _value, meta} -> {event_name, meta} end)
    |> Enum.each(fn {{event_name, meta}, metrics} ->
      reports =
        Enum.map(metrics, fn {_event_name, type, value, _meta} ->
          "#{to_string(type)}: #{inspect(format_value(type, value))}\n"
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

  defp format_value(:summary, summary_data) do
    Summary.calculate(summary_data)
  end

  defp format_value(_, value) do
    value
  end

  @doc """
  Persist the metrics to disk
  """
  @spec save(Mobius.name()) :: :ok | {:error, reason :: term()}
  def save(name \\ @default_args[:name]) do
    start_t = System.monotonic_time()
    prefix = [:mobius, :save]
    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, %{name: name})

    with :ok <- Scraper.save(name),
         :ok <- MetricsTable.Monitor.save(name) do
      duration = System.monotonic_time() - start_t
      :telemetry.execute(prefix ++ [:stop], %{duration: duration}, %{name: name})

      :ok
    else
      error ->
        duration = System.monotonic_time() - start_t

        :telemetry.execute(
          prefix ++ [:exception],
          %{reason: inspect(error), duration: duration},
          %{name: name}
        )

        error
    end
  end

  @type make_bundle_opt() :: {:name, name()}

  @doc """
  Function for creating a `Mobius.Bundle.t()`

  This function makes a bundle that can be used with the functions in
  `Mobius.Bundle`
  """
  @spec make_bundle(Bundle.target(), [make_bundle_opt()]) :: Bundle.t()
  def make_bundle(bundle_target, opts \\ []) do
    mobius_name = opts[:name] || :mobius
    data = Scraper.all(mobius_name)

    Bundle.new(bundle_target, data)
  end
end
