defmodule Mobius.Exports do
  @moduledoc """
  Support retrieving historical data in different formats

  Current formats:

  * CSV
  * Series
  * Line plot
  """

  alias Mobius.Exports.UnsupportedMetricError

  @typedoc """
  Options to use when exporing time series metric data

  * `:mobius_instance` - the name of the Mobius instance you are using. Unless
    you specified this in your configuration you should be safe to allow this
    option to default, which is `:mobius_metrics`.
  * `:last` - display data point that have been captured over the last `x`
    amount of time. Where `x` is either an integer or a tuple of
    `{integer(), time_unit()}`. If you only pass an integer the time unit of
    `:seconds` is assumed. By default Mobius will plot the last 3 minutes of
    data.
  * `:from` - the unix timestamp, in seconds, to start querying from
  * `:to` - the unix timestamp, in seconds, to stop querying at
  """
  @type export_opt() ::
          {:mobius_instance, atom()}
          | {:from, integer()}
          | {:to, integer()}
          | {:last, integer() | {integer(), Mobius.time_unit()}}

  @typedoc """
  Options for exporting a CSV
  """
  @type csv_export_opt() ::
          export_opt()
          | {:headers, boolean()}
          | {:iodevice, IO.device()}

  @doc """
  Generate a CSV for the metric

  Please see `Mobius.Exporters.CSV` for more information.

  ```elixir
  # Return CSV as string
  {:ok, csv_string} = Mobius.Exports.csv("vm.memory.total", :last_value, %{})

  # Write to console
  Mobius.Exports.csv("vm.memory.total", :last_value, %{}, iodevice: :stdio)

  #Write to a file
  file = File.open("mycsv.csv", [:write])
  :ok = Mobius.Exports.csv("vm.memory.total", :last_value, %{}, iodevice: file)
  ```
  """
  @spec csv(binary(), Mobius.metric_type(), map(), [csv_export_opt()]) ::
          :ok | {:ok, binary()} | {:error, UnsupportedMetricError.t()}
  def csv(metric_name, type, tags, opts \\ []) do
    case get_metrics(metric_name, type, tags, opts) do
      {:ok, metrics} ->
        export_opts = build_exporter_opts(metric_name, type, tags, opts)
        Mobius.Exports.CSV.export_metrics(metrics, export_opts)

      error ->
        error
    end
  end

  @doc """
  Generates a series that contains the value of the metric
  """
  @spec series(String.t(), Mobius.metric_type(), map(), [export_opt()]) ::
          {:ok, [integer()]} | {:error, UnsupportedMetricError.t()}
  def series(metric_name, type, tags, opts \\ []) do
    case get_metrics(metric_name, type, tags, opts) do
      {:ok, metrics} ->
        {:ok, Enum.map(metrics, fn metric -> metric.value end)}

      error ->
        error
    end
  end

  @doc """
  Retrieve the raw metric data from the history store for a given metric.

  Output will be a list of metric values, which will be in the format, eg:
    `%{type: :last_value, value: 12, tags: %{interface: "eth0"}, timestamp: 1645107424}`

    If there are tags for the metric you can pass those in the third argument:

  ```elixir
  Mobius.Exports.metrics("vm.memory.total", :last_value, %{some: :tag})
  ```

  By default the filter will display the last 3 minutes of metric history.

  However, you can pass the `:from` and `:to` options to look at a specific
  range of time.

  ```elixir
  Mobius.Exports.metrics("vm.memory.total", :last_value, %{}, from: 1630619212, to: 1630619219)
  ```

  You can also filter data over the last `x` amount of time. Where x is an
  integer. When there is no `time_unit()` provided the unit is assumed to be
  `:second`.

  Retrieving data over the last 30 seconds:

  ```elixir
  Mobius.Exports.metrics("vm.memory.total", :last_value, %{}, last: 30)
  ```

  Retrieving data over the last 2 hours:

  ```elixir
  Mobius.Exports.metrics("vm.memory.total", :last_value, %{}, last: {2, :hour})
  ```
  """
  @spec metrics(binary(), Mobius.metric_type(), map(), [export_opt()] | keyword()) ::
          {:ok, [Mobius.metric()]} | {:error, UnsupportedMetricError.t()}
  def metrics(metric_name, type, tags, opts \\ [])

  def metrics(_metric_name, :summary, _tags, _opts) do
    {:error, UnsupportedMetricError.exception(metric_type: :summary)}
  end

  def metrics(metric_name, type, tags, opts) do
    {:ok, Mobius.Exports.Metrics.export(metric_name, type, tags, opts)}
  end

  defp get_metrics(metric_name, type, tags, opts) do
    filter_metrics_opts =
      opts
      |> Keyword.put_new(:mobius_instance, :mobius)
      |> Keyword.take([:metic_name, :type, :tags, :mobius_instance, :from, :to, :last])

    metrics(metric_name, type, tags, filter_metrics_opts)
  end

  defp build_exporter_opts(metric_name, type, tags, opts) do
    opts
    |> Keyword.put_new(:metric_name, metric_name)
    |> Keyword.put_new(:type, type)
    |> Keyword.put_new(:tags, Map.keys(tags))
  end

  @doc """
  Plot the metric name to the screen

  This takes the same arguments as for filter_metrics, eg:

  If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.Exports.plot("vm.memory.total", :last_value, %{some: :tag})
  ```

  By default the plot will display the last 3 minutes of metric history.

  However, you can pass the `:from` and `:to` options to look at a specific
  range of time.

  ```elixir
  Mobius.Exports.plot("vm.memory.total", :last_value, %{}, from: 1630619212, to: 1630619219)
  ```

  You can also plot data over the last `x` amount of time. Where x is an
  integer. When there is no `time_unit()` provided the unit is assumed to be
  `:second`.

  Plotting data over the last 30 seconds:

  ```elixir
  Mobius.Export.plot("vm.memory.total", :last_value, %{}, last: 30)
  ```

  Plotting data over the last 2 hours:

  ```elixir
  Mobius.Export.plot("vm.memory.total", :last_value, %{}, last: {2, :hour})
  ```
  """
  @spec plot(binary(), Mobius.metric_type(), map(), [export_opt()]) :: :ok
  def plot(metric_name, type, tags \\ %{}, opts \\ []) do
    with {:ok, series} <- series(metric_name, type, tags, opts),
         {:ok, plot} <- Mobius.Asciichart.plot(series, height: 12) do
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
    else
      error -> error
    end
  end
end
