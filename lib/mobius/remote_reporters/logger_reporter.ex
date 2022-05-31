defmodule Mobius.RemoteReporters.LoggerReporter do
  @moduledoc """
  Example remote reporter that logs the first and last metric

  This logger is used in the example application.
  """

  @behaviour Mobius.RemoteReporter

  require Logger

  @impl Mobius.RemoteReporter
  def init(_) do
    {:ok, nil}
  end

  @impl Mobius.RemoteReporter
  def handle_metrics(metrics, state) do
    groups =
      Enum.group_by(metrics, fn %{name: name, tags: tags, type: type} -> {name, type, tags} end)

    out =
      Enum.reduce(groups, "", fn {{name, type, tags}, grouped_metrics}, str ->
        first = List.first(grouped_metrics)
        last = List.last(grouped_metrics)

        str <>
          """
          #{name}, #{inspect(type)}, #{inspect(tags)}

          First: #{inspect(first.timestamp)}: #{inspect(first.value)}
          Last: #{inspect(last.timestamp)}: #{inspect(last.value)}

          """
      end)

    Logger.info("""

    ======

    Mobius LoggerReporter:

    #{out}
    ======
    """)

    {:noreply, state}
  end
end
