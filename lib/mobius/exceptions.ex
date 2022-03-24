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

defmodule Mobius.Exports.MBFParseError do
  @moduledoc """
  Use when there is an error parsing a Mobius Binary Format (MBF) binary
  """

  @type t() :: %__MODULE__{
          message: binary(),
          error: atom()
        }

  defexception [:message, :error]

  @impl Exception
  def exception(error) do
    %__MODULE__{
      error: error,
      message: "Error parsing mobius binary format binary because #{inspect(error)}"
    }
  end
end

defmodule Mobius.FileError do
  @moduledoc """
  Used when there is an error conducting file operations
  """

  defexception [:message, :error, :file, :operation]

  @type t() :: %__MODULE__{
          message: binary(),
          error: atom(),
          file: Path.t(),
          operation: binary()
        }

  @impl Exception
  def exception(opts) do
    error = Keyword.fetch!(opts, :error)
    file = Keyword.fetch!(opts, :file)
    operation = Keyword.fetch!(opts, :operation)

    %__MODULE__{
      error: error,
      message:
        "Could not #{inspect(operation)} file #{inspect(file)} for reason: {inspect(error)}",
      file: file,
      operation: operation
    }
  end
end
