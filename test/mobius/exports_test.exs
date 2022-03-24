defmodule Mobius.ExportsTest do
  use ExUnit.Case, async: true

  alias Mobius.Exports
  alias Mobius.Exports.MobiusBinaryFormat

  @tag :tmp_dir
  test "export and parse version 1 Mobius Binary Format to binary", %{tmp_dir: tmp_dir} do
    metrics = [
      Telemetry.Metrics.last_value("make.mbf.value"),
      Telemetry.Metrics.last_value("make.another.value")
    ]

    args = Keyword.put(make_args(tmp_dir), :metrics, metrics)

    {:ok, _} = start_supervised({Mobius, args})
    execute_telemetry([:make, :mbf], %{value: 100})
    execute_telemetry([:make, :another], %{value: 100})

    # make sure there's time for the scrapper
    Process.sleep(1_000)

    mbf = Exports.mbf()

    assert {:ok, metrics} = Exports.parse_mbf(mbf)

    assert is_list(metrics)
    assert Enum.all?(metrics, fn m -> m.name in ["make.mbf.value", "make.another.value"] end)
  end

  @tag :tmp_dir
  test "export version 1 Mobius Binary Format to file", %{tmp_dir: tmp_dir} do
    {:ok, _} = start_supervised({Mobius, make_args(tmp_dir)})
    expected_bin = MobiusBinaryFormat.to_iodata([]) |> IO.iodata_to_binary()

    {:ok, file} = Exports.mbf(out_dir: tmp_dir)

    assert File.read!(file) == expected_bin
  end

  defp make_args(persistence_dir) do
    [
      metrics: [],
      persistence_dir: persistence_dir
    ]
  end

  defp execute_telemetry(event, measurements) do
    :telemetry.execute(event, measurements, %{})
  end
end
