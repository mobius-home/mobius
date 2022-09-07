defmodule Mobius.EventLog do
  @moduledoc """
  API for working with the event log
  """

  alias Mobius.{Event, EventsServer}

  @event_log_binary_format_version 1

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

  @doc """
  Return the event log in the Mobius binary format
  """
  @spec to_binary([opt()]) :: binary()
  def to_binary(opts \\ []) do
    opts
    |> list()
    |> events_to_binary()
  end

  @doc """
  Turn a list of Events into a binary
  """
  @spec events_to_binary([Event.t()]) :: binary()
  def events_to_binary(events) do
    bin = :erlang.term_to_binary(events)

    <<@event_log_binary_format_version, bin::binary>>
  end

  @doc """
  Save the current state of the event log to disk
  """
  @spec save([opt()]) :: :ok
  def save(opts \\ []) do
    instance = opts[:instance] || :mobius
    bin = to_binary(opts)

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
