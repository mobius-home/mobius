defmodule Mobius.BufferTest do
  use ExUnit.Case, async: true

  alias Mobius.Buffer

  test "inserts correctly" do
    {:ok, my_buffer} = Buffer.start_link(resolution: :minute)

    dt = DateTime.utc_now()
    metric = {[:my, :metric], :counter, 1, %{hello: :world}}

    :ok = Buffer.insert(my_buffer, :minute, dt, [metric])

    assert [{dt, [metric]}] == Buffer.to_list(my_buffer, :minute)
  end
end
