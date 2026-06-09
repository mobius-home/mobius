defmodule Mobius.ExceptionsTest do
  use ExUnit.Case, async: true

  describe "Mobius.FileError" do
    test "message contains the inspected error reason" do
      error =
        Mobius.FileError.exception(error: :enoent, file: "/data/history", operation: "read")

      assert error.message =~ ":enoent"
      assert error.message =~ ~s("read")
      assert error.message =~ ~s("/data/history")
    end
  end
end
