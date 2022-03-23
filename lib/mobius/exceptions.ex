defmodule Mobius.DataLoadError do
  @moduledoc """
  Used when there is problem loading data into the mobius storage
  """

  defexception [:message, :reason]

  @type t() :: %__MODULE__{
          message: binary(),
          reason: atom()
        }

  @typedoc """
  Options for making a `DataLoadError`

  - `:reason` - the reason why the data could not be loaded
  """
  @type opt() :: {:reason, atom()}

  @impl Exception
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      message: "Unable to load data because of #{inspect(reason)}",
      reason: reason
    }
  end
end

defmodule Mobius.Exports.UnsupportedMetricError do
  @moduledoc """
  Error for trying to export metric types where there is no support in the
  export implementation
  """

  defexception [:message, :metric_type]

  @type t() :: %__MODULE__{
          message: binary(),
          metric_type: Mobius.metric_type()
        }

  @impl Exception
  def exception(opts) do
    type = Keyword.fetch!(opts, :metric_type)

    %__MODULE__{
      message: "Exporting metrics of type #{inspect(type)} is not supported",
      metric_type: type
    }
  end
end
