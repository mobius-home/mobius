defmodule Mobius do
  @moduledoc """
  Local telemetry metrics reporter
  """

  use Supervisor

  alias Mobius.Metrics.Table
  alias Mobius.History

  alias Telemetry.Metrics

  @typedoc """
  Arguments for the `Mobius` reporter

  * `:metrics` - list of telemetry metrics `Mobius` should report (required)
  * `:snapshot_interval` - the interval (in miliseconds) to record metric history
    (optional, default: `1_000`)
  * `:history_size` - number of metric records to keep in history (optional,
    defaul: `500`)
  * `:table_name` - the metrics table name (optional, deafult:
    `Mobius.MetricsTable`)
  """
  @type arg() ::
          {:metrics, [Metrics.t()]}
          | {:table_name, atom()}
          | {:history_size, non_neg_integer()}
          | {:snapshot_interval, non_neg_integer()}

  @type info_opt() :: {:table_name, atom()}

  @spec start_link([arg()]) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: Mobius.Supervisor)
  end

  @impl Supervisor
  def init(args) do
    args = Keyword.put_new_lazy(args, :table_name, fn -> Table end)

    # by creating the ETS table here we tie it to the supervisor process
    # so the table should stay around unless this supervisor crashes.
    :ok = Table.init(args)

    children = [
      {Mobius.Reporter, args},
      {Mobius.History, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Plot metric information to the console
  """
  @spec plot() :: :ok
  def plot() do
    History.view(limit: 340)
    |> Enum.flat_map(fn {_timestamp, metric} -> metric end)
    |> Enum.group_by(fn {event_name, event_type, _data, meta} ->
      {event_name, event_type, meta}
    end)
    |> Enum.each(fn {{event_name, type, meta}, ms} ->
      series = Enum.map(ms, fn {_en, _et, value, _meta} -> value end)
      {:ok, chart} = Mobius.Asciichart.plot(series, height: 10)

      chart = [
        "\t\t",
        IO.ANSI.yellow(),
        "Event: ",
        make_event_name(event_name, type),
        IO.ANSI.reset(),
        ", ",
        IO.ANSI.magenta(),
        "Metric: #{inspect(type)}, ",
        IO.ANSI.cyan(),
        "Tags: #{inspect(meta)}",
        IO.ANSI.reset(),
        "\n\n",
        chart
      ]

      IO.puts(chart)
    end)
  end

  defp make_event_name(event_name, :counter),
    do: event_name |> Enum.take(length(event_name) - 1) |> Enum.join(".")

  defp make_event_name(event_name, _type), do: Enum.join(event_name, ".")

  @doc """
  Print current metric information to the console
  """
  @spec info([info_opt()]) :: :ok
  def info(opts \\ []) do
    opts
    |> Keyword.get(:table_name, Table)
    |> Table.get_entries()
    |> Enum.group_by(fn {event_name, _type, _value, meta} -> {event_name, meta} end)
    |> Enum.each(fn {{event_name, meta}, metrics} ->
      reports =
        Enum.map(metrics, fn {_event_name, type, value, _meta} ->
          "#{to_string(type)}: #{inspect(value)}\n"
        end)

      [
        "Event: ",
        Enum.join(event_name, "."),
        "\n",
        "Tags: #{inspect(meta)}\n",
        reports
      ]
      |> IO.puts()
    end)
  end
end
