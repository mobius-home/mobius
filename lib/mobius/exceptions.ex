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
      message: "Unable to load data because of #{inspect(reason)}"
    }
  end
end
