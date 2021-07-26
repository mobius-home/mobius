defmodule Mobius.Charts do
  @moduledoc """
  Module for plotting and reporting about metric data
  """

  alias Mobius.{Buffer, MetricsTable}

  @typedoc """
  Options to use when plotting time series metric data

  * `:resolution` - at what time scale you want to see the past event
    (default `:minute`)
  * `:name` - the name of the Mobius instance you are using. Unless you
    specified this in your configuration you should be safe to allow this
    option to default, which is `:mobius_metrics`.
  """
  @type plot_opt() :: {:resolution, Mobius.resolution()} | {:name, Mobius.name()}

  @doc """
  Plot the metric name to the screen

  If there are tags for the metric you can pass those in the second argument:

  ```elixir
  Mobius.Charts.plot("vm.memory.total", %{some: :tag})
  ```

  Optionally you can pass in a resolution to see the metrics recorded over time
  specified by the resolution.

  ```elixir
  Mobius.Charts.plot("vm.memory.total", %{}, resolution: :hour)
  ```

  By default the resolution is `:minute`, which will display the metrics over
  the last minute.
  """
  @spec plot(binary(), map(), [plot_opt()]) :: :ok
  def plot(metric_name, tags \\ %{}, opts \\ []) do
    parsed_metric_name = parse_metric_name(metric_name)
    resolution = Keyword.get(opts, :resolution, :minute)

    series =
      opts
      |> Keyword.get(:name, :mobius_metrics)
      |> Buffer.to_list(resolution)
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
    name = name || :mobius_metrics

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
