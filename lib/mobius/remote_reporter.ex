defmodule Mobius.RemoteReporter do
  @moduledoc """
  Behaviour for modules that report mobius metrics to a remote server

  A remote reporter allows mobius to report metrics to a remote server at some
  configured interval.

  Say we have a remote reporter who needs an API token to communicate with a
  remote server. The implementation could look like:

  ```elixir
  defmodule MyRemoteReporter do
    @behaviour Mobius.RemoteReporter

    @impl Mobius.RemoteReporter
    def init(args) do
      token = Keyword.fetch!(args, :token)

      {:ok, %{token: token}}
    end

    @impl Mobius.RemoteReporter
    def handle_metrics(metrics, state) do
      # ...send metrics
      {:noreply, state}
    end
  end
  ```

  To use this implementation configure Mobius to report metrics every minute
  (the default).

  ```elixir
  def start(_type, _args) do
    metrics = [
      Metrics.last_value("my.telemetry.event"),
    ]

    children = [
      # ... other children ....
      {Mobius,
        metrics: metrics,
        remote_reporter:
          {MyRemoteReporter,
            token: "s3curity"},
        remote_report_interval: 60_000}
      # ... other children ....
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  If you do not supply a `:remote_report_interval` value the remote reporter
  will not be ran. This is useful for programmatic on demand reporting. If you
  want Mobius to  automatically report metrics at an interval you have to set
  `:remote_report_interval` in the Mobius options.
  """

  @typedoc """
  Module that implements the `Mobius.RemoteReporter` behaviour
  """
  @type t() :: module()

  @doc """
  Initialize the reporter

  This callback will receive any configured arguments. These are specific to the
  reporter implementation but some options might be tokens, host names, ports,
  etc.
  """
  @callback init(opts :: term()) :: {:ok, state :: term()}

  @doc """
  Handle when metrics are ready to be reported

  This callback will receive a list of metrics and can preform any operation it
  is designed to do.

  The report will only receive the metric from the last report time until the
  current time, so the implementation does not need to worry about querying
  only the newest metrics.
  """
  @callback handle_metrics([Mobius.metric()], state :: term()) ::
              {:noreply, state :: term()} | {:error, reason :: term(), state :: term()}

  @doc """
  Trigger metrics to be reported
  """
  @spec report_metrics(Mobius.instance()) :: :ok
  def report_metrics(instance \\ :mobius) do
    Mobius.RemoteReporterServer.report_metrics(instance)
  end
end
