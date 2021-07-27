defmodule Mobius.Resolutions do
  @moduledoc false

  @doc """
  Get the number of items in each resolution
  """
  @spec resolution_to_size(Mobius.resolution()) :: pos_integer()
  def resolution_to_size(:month), do: 31
  def resolution_to_size(:week), do: 7
  def resolution_to_size(:day), do: 24
  def resolution_to_size(:hour), do: 60
  def resolution_to_size(:minute), do: 60

  @doc """
  The interval of time in milliseconds between each resolution data point
  """
  @spec resolution_interval(Mobius.resolution()) :: pos_integer()
  # every 24 hours
  def resolution_interval(:month), do: 86_400_000
  # every 24 horus
  def resolution_interval(:week), do: 86_400_000
  # every hour
  def resolution_interval(:day), do: 3_600_000
  # every minute
  def resolution_interval(:hour), do: 60_000
  # every second
  def resolution_interval(:minute), do: 1000
end
