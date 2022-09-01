defmodule Mobius.EventLog do
  @moduledoc """
  API for working with the event log
  """

  @event_log_binary_format_version 1

  alias Mobius.{Event, EventsServer}

  @doc """
  List the events in the event log
  """
  @spec list(Mobius.instance()) :: [Event.t()]
  def list(instance \\ :mobius) do
    EventsServer.list(instance)
  end

  @doc """
  Return the event log in the Mobius binary format
  """
  @spec to_binary(Mobius.instance()) :: binary()
  def to_binary(instance \\ :mobius) do
    events = list(instance)
    bin = :erlang.term_to_binary(events)

    <<@event_log_binary_format_version, bin::binary>>
  end

  @doc """
  Save the current state of the event log to disk
  """
  @spec save(Mobius.instance()) :: :ok
  def save(instance \\ :mobius) do
    bin = to_binary(instance)

    EventsServer.save(instance, bin)
  end

  @doc """
  Parse the Mobius binary formatted event log
  """
  @spec parse(binary()) :: {:ok, [Event.t()]} | {:error, atom()}
  def parse(<<0x01, event_log_bin::binary>>) do
    {:ok, :erlang.binary_to_term(event_log_bin)}
  end

  def parse(_binary) do
    {:error, :invalid_binary_format}
  end
end
