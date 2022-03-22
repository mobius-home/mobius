defmodule MobiusTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @persistence_dir System.tmp_dir!() |> Path.join("mobius_test")
  @default_args [
    persistence_dir: @persistence_dir,
    metrics: []
  ]
  @default_name "mobius"

  setup do
    File.rm_rf!(@persistence_dir)
    File.mkdir_p(@persistence_dir)
  end

  test "starts" do
    assert {:ok, _pid} = start_supervised({Mobius, @default_args})
  end

  test "does not crash with a corrupt history file" do
    persistence_path = Path.join(@persistence_dir, @default_name)
    File.mkdir_p(persistence_path)
    File.write!(file(persistence_path), <<>>)

    assert capture_log(fn ->
             assert {:ok, _pid} = start_supervised({Mobius, @default_args})
           end) =~ "Unable to load data because of :unsupported_version"
  end

  test "can save persistence data" do
    persistence_path = Path.join(@persistence_dir, @default_name)
    {:ok, _pid} = start_supervised({Mobius, @default_args})

    assert :ok = Mobius.save(@default_name)
    assert File.exists?(Path.join(persistence_path, "history"))
    assert File.exists?(Path.join(persistence_path, "metrics_table"))
  end

  test "can autosave persistence data" do
    persistence_path = Path.join(@persistence_dir, @default_name)
    {:ok, _pid} = start_supervised({Mobius, @default_args ++ [autosave_interval: 1]})
    refute File.exists?(Path.join(persistence_path, "history"))

    # Sleep for a bit and check we autosaved in the meantime
    Process.sleep(1_100)
    assert File.exists?(Path.join(persistence_path, "history"))
    assert File.exists?(Path.join(persistence_path, "metrics_table"))
  end

  defp file(persistence_dir) do
    Path.join(persistence_dir, "history")
  end
end
