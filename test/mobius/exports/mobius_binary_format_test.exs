defmodule Mobius.Exports.MobiusBinaryFormatTest do
  use ExUnit.Case, async: true

  alias Mobius.Exports.MobiusBinaryFormat
  alias Mobius.Exports.MBFParseError

  test "parsing version 1 Mobius Binary Format" do
    metrics = [
      %{name: "test.m", value: 1, timestamp: 1, tags: %{}, type: :counter}
    ]

    mbf =
      MobiusBinaryFormat.to_iodata(metrics)
      |> IO.iodata_to_binary()

    assert {:ok, ^metrics} = MobiusBinaryFormat.parse(mbf)
  end

  test "error parsing mbf binary with wrong metric information" do
    invalid_binary = <<1, 4>>
    error = MBFParseError.exception(:corrupt)

    assert {:error, error} == MobiusBinaryFormat.parse(invalid_binary)
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

    assert {:error, error} == MobiusBinaryFormat.parse(missing_metric_fields)
    assert {:error, error} == MobiusBinaryFormat.parse(bad_metric_timestamp)
    assert {:error, error} == MobiusBinaryFormat.parse(bad_metric_name)
    assert {:error, error} == MobiusBinaryFormat.parse(bad_metric_type)
    assert {:error, error} == MobiusBinaryFormat.parse(bad_metric_value)
    assert {:error, error} == MobiusBinaryFormat.parse(bad_metric_tags)
  end
end
