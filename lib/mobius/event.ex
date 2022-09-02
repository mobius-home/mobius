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
  @type new_opt() :: {:group, atom()} | {:timestamp, integer()}

  @typedoc """
  An event
  """
  @type t() :: %__MODULE__{
          name: name(),
          measurements: map(),
          tags: map(),
          group: atom(),
          timestamp: pos_integer() | nil,
          session: Mobius.session()
        }

  defstruct name: nil,
            measurements: %{},
            tags: %{},
            group: :default,
            timestamp: nil,
            session: nil

  @doc """
  Create a new event
  """
  @spec new(Mobius.session(), name(), map(), map(), [new_opt()]) :: t()
  def new(session, name, measurements, tags, opts \\ []) do
    group = opts[:group] || :default
    timestamp = get_timestamp(opts)

    %__MODULE__{
      name: name_to_string(name),
      measurements: measurements,
      timestamp: timestamp,
      tags: tags,
      group: group,
      session: session
    }
  end

  defp get_timestamp(opts) do
    case opts[:timestamp] do
      nil -> System.system_time(:second)
      timestamp -> timestamp
    end
  end

  def set_timestamp(event, timestamp) do
    %{event | timestamp: timestamp}
  end

  defp name_to_string(name) when is_list(name) do
    Enum.join(name, ".")
  end

  defp name_to_string(name) when is_binary(name) do
    name
  end
end
