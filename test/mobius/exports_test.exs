defmodule Mobius.ExportsTest do
  use ExUnit.Case, async: true

  alias Mobius.Exports
  alias Mobius.Exports.{MBFParseError, MobiusBinaryFormat}

  @tag :tmp_dir
  test "export version 1 Mobius Binary Format to binary", %{tmp_dir: tmp_dir} do
    {:ok, _} = start_supervised({Mobius, make_args(tmp_dir)})
    expected_bin = MobiusBinaryFormat.to_iodata([]) |> IO.iodata_to_binary()

    assert Exports.to_mbf() == expected_bin
  end

  @tag :tmp_dir
  test "export version 1 Mobius Binary Format to file", %{tmp_dir: tmp_dir} do
    {:ok, _} = start_supervised({Mobius, make_args(tmp_dir)})
    expected_bin = MobiusBinaryFormat.to_iodata([]) |> IO.iodata_to_binary()

    {:ok, file} = Exports.to_mbf(out_dir: tmp_dir)

    assert File.read!(file) == expected_bin
  end

  test "parsing version 1 Mobius Binary Format" do
    metrics = [
      %{name: "test.m", value: 1, timestamp: 1, tags: %{}, type: :counter}
    ]

    mbf =
      MobiusBinaryFormat.to_iodata(metrics)
      |> IO.iodata_to_binary()

    assert {:ok, ^metrics} = Exports.from_mbf(mbf)
  end

  test "error parsing mbf binary with wrong metric information" do
    invalid_binary = <<1, 4>>
    error = MBFParseError.exception(:corrupt)

    assert {:error, error} == Exports.from_mbf(invalid_binary)
  end

  test "error parsing bad metrics" do
    error = MBFParseError.exception(:invalid_format)
    missing_metric_fields = MobiusBinaryFormat.to_iodata([%{name: ""}])

    bad_metric_timestamp =
      MobiusBinaryFormat.to_iodata([
        %{name: "", timestamp: "", type: :last_value, value: 123, tags: %{}}
      ])

    bad_metric_name =
      MobiusBinaryFormat.to_iodata([
        %{name: 123, timestamp: 123, type: :last_value, value: 123, tags: %{}}
      ])

    bad_metric_type =
      MobiusBinaryFormat.to_iodata([
        %{name: "", timestamp: 123, type: :another_type, value: 123, tags: %{}}
      ])

    bad_metric_tags =
      MobiusBinaryFormat.to_iodata([
        %{name: "", timestamp: 123, type: :last_value, value: 123, tags: []}
      ])

    bad_metric_value =
      MobiusBinaryFormat.to_iodata([
        %{name: "", timestamp: 123, type: :last_value, value: "a value", tags: %{}}
      ])

    assert {:error, error} == Exports.from_mbf(missing_metric_fields)
    assert {:error, error} == Exports.from_mbf(bad_metric_timestamp)
    assert {:error, error} == Exports.from_mbf(bad_metric_name)
    assert {:error, error} == Exports.from_mbf(bad_metric_type)
    assert {:error, error} == Exports.from_mbf(bad_metric_value)
    assert {:error, error} == Exports.from_mbf(bad_metric_tags)
  end

  defp make_args(persistence_dir) do
    [
      metrics: [],
      persistence_dir: persistence_dir
    ]
  end
end
