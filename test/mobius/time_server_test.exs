defmodule Mobius.TimeServerTest do
  use ExUnit.Case, async: false

  alias Mobius.TimeServer

  defmodule TestClock do
    @behaviour Mobius.Clock

    @impl Mobius.Clock
    def synchronized?() do
      :persistent_term.get({__MODULE__, :synchronized?}, false)
    end

    def set_synchronized(value) do
      :persistent_term.put({__MODULE__, :synchronized?}, value)
    end
  end

  test "adjustment reflects only the clock step, not the time spent waiting for sync" do
    TestClock.set_synchronized(false)
    on_exit(fn -> :persistent_term.erase({TestClock, :synchronized?}) end)

    start_supervised!(
      {TimeServer, [mobius_instance: :time_server_test, clock: TestClock, session: "test"]}
    )

    :ok = TimeServer.register(:time_server_test, self())

    # Let real time pass between boot and sync detection. The wall clock
    # never steps in this test, so the true adjustment is ~0.
    Process.sleep(1_500)
    TestClock.set_synchronized(true)

    assert_receive {Mobius.TimeServer, _sync_timestamp, adjustment}, 5_000

    adjustment_ms = System.convert_time_unit(adjustment, :native, :millisecond)
    assert abs(adjustment_ms) < 500
  end
end
