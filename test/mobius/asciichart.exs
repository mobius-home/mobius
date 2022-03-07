defmodule Mobius.AsciichartTest do
  use ExUnit.Case, async: false

  alias Mobius.Asciichart

  test "Can generate a chart with nonvarying values" do
    # Ensure that we don't blow up when creating a chart with a single row of unvarying values
    assert {:ok, plot} = Asciichart.plot([1, 1, 1, 1])
    assert plot == {:ok, "1.00 ┼───  \n        "}
  end
end
