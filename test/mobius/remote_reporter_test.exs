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

  @tag timeout: 65_000
  test "handle_metrics/2 is called via report_metrics/1 function" do
    {:ok, _pid} =
      start_supervised(
        {Mobius,
         persistence_dir: "/tmp",
         mobius_instance: :reporter_test,
         metrics: [],
         remote_reporter: {TestRemoteReporter, receiver: self()}}
      )

    # ensure no messages are received automatically, we use 60 seconds here
    # because older implementation defaults for 60 seconds when no interval is
    # supplied
    refute_receive :got_metrics, 60_000

    :ok = Mobius.RemoteReporterServer.report_metrics(:reporter_test)

    # should receive right away
    assert_receive :got_metrics, 1_000
  end
end
