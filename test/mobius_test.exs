defmodule MobiusTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @persistence_dir System.tmp_dir!() |> Path.join("mobius_test")
  @default_args [
    persistence_dir: @persistence_dir,
    metrics: []
  ]

  setup do
    File.rm_rf!(@persistence_dir)
    File.mkdir_p(@persistence_dir)
  end

  test "starts" do
    assert {:ok, _pid} = start_supervised({Mobius, @default_args})
  end

  test "does not crash with a corrupt history file" do
    persistence_path = Path.join(@persistence_dir, "mobius")
    File.mkdir_p(persistence_path)
    File.write!(file(persistence_path), <<>>)

    assert capture_log(fn ->
             assert {:ok, _pid} = start_supervised({Mobius, @default_args})
           end) =~ "Error reading history file"
  end

  defp file(persistence_dir) do
    Path.join(persistence_dir, "history")
  end
end
