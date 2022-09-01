defmodule Mobius.Event do
  @moduledoc """
  An single event
  """

  @typedoc """
  The name of the event
  """
  @type name() :: binary() | [atom()]

  @typedoc """
  Options for creating a new event
  """
  @type new_opt() :: {:group, atom()}

  @typedoc """
  An event
  """
  @type t() :: %__MODULE__{
          name: name(),
          measurements: map(),
          tags: map(),
          group: atom(),
          timestamp: pos_integer()
        }

  defstruct name: nil,
            measurements: %{},
            tags: %{},
            group: :default,
            timestamp: nil

  @doc """
  Create a new event
  """
  @spec new(name(), pos_integer(), map(), map(), [new_opt()]) :: t()
  def new(name, timestamp, measurements, tags, opts \\ []) do
    group = opts[:group] || :default

    %__MODULE__{
      name: name_to_string(name),
      measurements: measurements,
      timestamp: timestamp,
      tags: tags,
      group: group
    }
  end

  defp name_to_string(name) when is_list(name) do
    Enum.join(name, ".")
  end

  defp name_to_string(name) when is_binary(name) do
    name
  end
end
