defmodule Mobius.Clock do
  @moduledoc """
  Behaviour for Mobius to check if the clock is set

  On systems that need to set the time after boot events, metrics might
  report a nonsensical timestamp. Providing a clock implementation allows Mobius
  to make time adjustments on data received before the clock was set.

  If no clock implementation is provided no time adjustments will be made.

  For Nerves devices, [NervesTime](https://hex.pm/packages/nerves_time) can be
  used to track time synchronization.

  ```elixir
  {Mobius, clock: NervesTime}
  ```

  The time adjustments are best effort and might not be 100% exact, but this should
  only affect events that take place during the early stages of system boot.
  """

  @doc """
  Callback to check if the clock is synchronized
  """
  @callback synchronized?() :: boolean()
end
