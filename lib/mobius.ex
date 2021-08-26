defmodule Mobius do
  @moduledoc """
  Localized metrics reporter
  """

  use Supervisor

  alias Mobius.{MetricsTable, Scraper}

  alias Telemetry.Metrics

  @default_args [name: :mobius, persistence_dir: "/data"]

  @type time_unit() :: :second | :minute | :hour | :day

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
  * `:last` - display data point that have been captured over the last `x`
    amount of time. Where `x` is either an integer or a tuple of
    `{integer(), time_unit()}`. If you only pass an integer the time unit of
    `:seconds` is assumed. By default Mobius will plot the last 3 minutes of
    data.
  * `:from` - the unix timestamp, in seconds, to start querying from
  * `:to` - the unix timestamp, in seconds, to stop querying at
  """
  @type plot_opt() ::
          {:name, Mobius.name()}
          | {:last, integer() | {integer(), time_unit()}}
          | {:from, integer()}
          | {:to, integer()}

  @doc """
  Plot the metric name to the screen

  If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.Charts.plot("vm.memory.total", %{some: :tag})
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
    parsed_metric_name = parse_metric_name(metric_name)
    scraper_query_opts = query_opts(opts)

    series =
      opts
      |> Keyword.get(:name, :mobius)
      |> Scraper.all(scraper_query_opts)
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

  @type naming_opt :: :csv_ext | :timestamp
  @type csv_opt() ::
          {:file, String.t()}
          | {:naming, [naming_opt]}
          | {:last, integer() | {integer(), time_unit()}}
          | {:from, integer()}
          | {:to, integer()}

  @doc """
  Produces a CSV of currently collected metrics, optionally writing the CSV to file.
  The CSV looks like: timestamp, name, type, value, tag1, tag2, tag3..., tagN
  If tags are provided, only the metrics matching the tags are output to the CSV.
  If a writable file is given via the :file option, the CSV is written to it. Otherwise it is written to the terminal.
  If the optional :naming option contains :csv_ext, the .csv extension is added to the file name if not already present.
  If the optional :naming option list :timestamp, the file name is prefixed by a timestamp.

  Just as with plotting, metrics to be outputted to CSV can be restricted to a relative time period:

   * `:last` - metrics captured over the last `x`
    amount of time. Where `x` is either an integer or a tuple of
    `{integer(), time_unit()}`. If you only pass an integer the time unit of
    `:seconds` is assumed. By default the last 3 minutes of
    data will be outputted.
  * `:from` - the unix timestamp, in seconds, to start querying from
  * `:to` - the unix timestamp, in seconds, to stop querying at

  Examples:

  iex> Mobius.to_csv("vm.memory.total", %{})
  # -- writes CSV values to the terminal

  iex> Mobius.to_csv("vm.memory.total", %{}, file: "/data/csv/vm.memory.total")
  # -- writes CSV values to file vm.memory.total

  iex> Mobius.to_csv("vm.memory.total", %{}, file: "/data/csv/vm.memory.total", naming: [:csv_ext, :timestamp])
  # -- writes CSV values to a file like 20210830T174954_vm.memory.total.csv

  iex> Mobius.to_csv("vm.memory.total", %{})
  # -- writes CSV values to the terminal

  """
  @spec to_csv(String.t(), map, [csv_opt]) :: :ok
  def to_csv(metric_name, tags \\ %{}, opts \\ []) do
    parsed_metric_name = parse_metric_name(metric_name)

    rows =
      opts
      |> Keyword.get(:name, :mobius)
      |> Scraper.all(query_opts(opts))
      |> Enum.flat_map(fn {timestamp, metrics} ->
        rows_from_metrics(metrics, parsed_metric_name, tags, timestamp)
      end)

    tag_names = unique_tag_names(rows)

    headers_row =
      ["timestamp", "name", "type", "value"] ++
        for tag_name <- tag_names, do: Atom.to_string(tag_name)

    data_rows = data_rows(rows, metric_name, tag_names)

    csv([headers_row | data_rows], opts)
  end

  defp unique_tag_names(rows) do
    Enum.reduce(rows, MapSet.new(), fn row, set ->
      Enum.reduce(Map.keys(row.tags), set, fn tag_name, acc -> MapSet.put(acc, tag_name) end)
    end)
    |> Enum.sort()
  end

  defp data_rows(rows, metric_name, tag_names) do
    Enum.reduce(rows, [], fn row, acc ->
      tag_values = for tag_name <- tag_names, do: "#{Map.get(row.tags, tag_name, "")}"

      data_row =
        ["#{row.timestamp}", "#{metric_name}", "#{row.type}", "#{row.value}"] ++ tag_values

      acc ++ [data_row]
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

  defp series_for_metric_from_metrics(metrics, metric_name, tags) do
    Enum.reduce(metrics, [], fn
      {^metric_name, _type, value, ^tags}, ms ->
        ms ++ [value]

      _, ms ->
        ms
    end)
  end

  defp rows_from_metrics(metrics, metric_name, tags, timestamp) do
    Enum.reduce(metrics, [], fn
      {^metric_name, type, value, metric_tags}, rows ->
        if match?(^tags, metric_tags) do
          row = %{type: type, value: value, tags: metric_tags, timestamp: timestamp}

          rows ++ [row]
        else
          rows
        end

      _metric, rows ->
        rows
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
