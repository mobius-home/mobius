defmodule Mobius.ResolutionsTest do
  use ExUnit.Case, async: true

  alias Mobius.Resolutions

  describe "size of resolution" do
    test "month" do
      assert Resolutions.resolution_to_size(:month) == 31
    end

    test "week" do
      assert Resolutions.resolution_to_size(:week) == 7
    end

    test "day" do
      assert Resolutions.resolution_to_size(:day) == 24
    end

    test "hour" do
      assert Resolutions.resolution_to_size(:hour) == 60
    end

    test "minute" do
      assert Resolutions.resolution_to_size(:minute) == 60
    end
  end

  describe "intervals of resolution" do
    test "month" do
      assert Resolutions.resolution_interval(:month) == 86_400_000
    end

    test "week" do
      assert Resolutions.resolution_interval(:week) == 86_400_000
    end

    test "day" do
      assert Resolutions.resolution_interval(:day) == 3_600_000
    end

    test "hour" do
      assert Resolutions.resolution_interval(:hour) == 60_000
    end

    test "minute" do
      assert Resolutions.resolution_interval(:minute) == 1_000
    end
  end
end
