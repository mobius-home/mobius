defmodule Mobius.RemoteReporterTest do
  use ExUnit.Case, async: true

  defmodule TestRemoteReporter do
    @moduledoc false

    @behaviour Mobius.RemoteReporter

    @impl Mobius.RemoteReporter
    def init(args) do
      receiver = Keyword.fetch!(args, :receiver)

      {:ok, %{receiver: receiver}}
    end

    @impl Mobius.RemoteReporter
    def handle_metrics(_metrics, state) do
      send(state.receiver, :got_metrics)
      {:noreply, state}
    end
  end

  test "handle_metrics/2 is called" do
    {:ok, _pid} =
      start_supervised(
        {Mobius,
         persistence_dir: "/tmp",
         mobius_instance: :reporter_test,
         metrics: [],
         remote_reporter: {TestRemoteReporter, receiver: self()},
         remote_report_interval: 5_000}
      )

    assert_receive :got_metrics, 8_000
  end
end
