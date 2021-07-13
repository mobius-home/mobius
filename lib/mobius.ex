defmodule Mobius do
  @moduledoc """
  Local telemetry metrics reporter
  """

  use Supervisor

  alias Mobius.Metrics.Table
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
end
