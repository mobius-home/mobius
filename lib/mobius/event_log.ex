defmodule Mobius.EventLog do
  @moduledoc """
  API for working with the event log
  """

  alias Mobius.{Event, EventsServer}

  require Logger

  @event_log_binary_format_version 1
  @default_compression_level 9

  @typedoc """
  Options to query the event log
  """
  @type opt() :: {:from, integer()} | {:to, integer()} | {:instance, Mobius.instance()}

  @doc """
  List the events in the event log
  """
  @spec list([opt()]) :: [Event.t()]
  def list(opts \\ []) do
    instance = opts[:instance] || :mobius
    EventsServer.list(instance, opts)
  end

  @typedoc """
  Options for serializing the event log

  * `:compression_level` - the zlib level (`0..9`) used to compress the payload,
    defaults to `9`. `0` disables compression.
  """
  @type serialize_opt() :: {:compression_level, 0..9}

  @doc """
  Return the event log in the Mobius binary format
  """
  @spec to_binary([opt() | serialize_opt()]) :: binary()
  def to_binary(opts \\ []) do
    opts
    |> list()
    |> events_to_binary(opts)
  end

  @doc """
  Turn a list of Events into a binary
  """
  @spec events_to_binary([Event.t()], [serialize_opt()]) :: binary()
  def events_to_binary(events, opts \\ []) do
    compression_level = opts[:compression_level] || @default_compression_level
    bin = :erlang.term_to_binary(events, [{:compressed, compression_level}])

    <<@event_log_binary_format_version, bin::binary>>
  end

  @doc """
  Save the current state of the event log to disk

  The configured compression level for the instance is applied by the events
  server when it writes the file.
  """
  @spec save([opt()]) :: :ok
  def save(opts \\ []) do
    instance = opts[:instance] || :mobius

    EventsServer.save(instance)
  end

  @doc """
  Clear the event log

  Empties the in-memory event log and removes the persisted event log file
  for the instance.
  """
  @spec clear([opt()]) :: :ok
  def clear(opts \\ []) do
    instance = opts[:instance] || :mobius
    EventsServer.clear(instance)
  end

  @doc """
  Parse the Mobius binary formatted event log
  """
  @spec parse(binary()) :: {:ok, [Event.t()]} | {:error, atom()}
  def parse(<<0x01, event_log_bin::binary>>) do
    case :erlang.binary_to_term(event_log_bin) do
      events when is_list(events) ->
        {:ok, drop_invalid_events(events)}

      _other ->
        {:error, :corrupt_event_log}
    end
  rescue
    ArgumentError -> {:error, :corrupt_event_log}
  end

  def parse(_binary) do
    {:error, :invalid_binary_format}
  end

  # Entries recorded under a different `Event` struct shape (or damaged on
  # disk) decode to terms that no longer match the current struct, so drop
  # them rather than letting them crash callers downstream.
  defp drop_invalid_events(events) do
    {valid, invalid} = Enum.split_with(events, &valid_event?/1)

    if invalid != [] do
      Logger.warning("[Mobius] Dropping #{length(invalid)} invalid persisted event log entries")
    end

    valid
  end

  defp valid_event?(%Event{} = event), do: Map.keys(event) == Map.keys(%Event{})
  defp valid_event?(_other), do: false
end
