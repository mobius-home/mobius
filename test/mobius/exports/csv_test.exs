defmodule Mobius.Exporters.CSVTest do
  use ExUnit.Case, async: true

  alias Mobius.Exports.CSV
  import ExUnit.CaptureIO

  setup do
    metrics_no_tags = [
      %{timestamp: 1, type: :last_value, value: 10, tags: %{}},
      %{timestamp: 2, type: :last_value, value: 13, tags: %{}},
      %{timestamp: 4, type: :last_value, value: 15, tags: %{}},
      %{timestamp: 8, type: :last_value, value: 16, tags: %{}}
    ]

    metrics_extra_tags = [
      %{timestamp: 1, type: :last_value, value: 10, tags: %{extra: "info"}},
      %{timestamp: 2, type: :last_value, value: 13, tags: %{extra: "info"}},
      %{timestamp: 4, type: :last_value, value: 15, tags: %{extra: "stuff"}},
      %{timestamp: 8, type: :last_value, value: 16, tags: %{extra: "data"}}
    ]

    {:ok, metrics_no_tags: metrics_no_tags, metrics_extra_tags: metrics_extra_tags}
  end

  test "generates basic string", %{metrics_no_tags: metrics_no_tags} do
    {:ok, csv_string} = CSV.export_metrics(metrics_no_tags, tags: [], metric_name: "test")

    expected_string = """
    timestamp,name,type,value
    1,test,last_value,10
    2,test,last_value,13
    4,test,last_value,15
    8,test,last_value,16
    """

    assert csv_string == String.trim(expected_string, "\n")
  end

  test "generates CSV with no headers", %{metrics_no_tags: metrics_no_tags} do
    {:ok, csv_string} =
      CSV.export_metrics(metrics_no_tags, tags: [], metric_name: "test", headers: false)

    expected_string = """
    1,test,last_value,10
    2,test,last_value,13
    4,test,last_value,15
    8,test,last_value,16
    """

    assert csv_string == String.trim(expected_string, "\n")
  end

  test "generates CSV with tags", %{metrics_extra_tags: metrics} do
    {:ok, csv_string} = CSV.export_metrics(metrics, tags: [:extra], metric_name: "no.tag.test")

    expected_string = """
    timestamp,name,type,value,extra
    1,no.tag.test,last_value,10,info
    2,no.tag.test,last_value,13,info
    4,no.tag.test,last_value,15,stuff
    8,no.tag.test,last_value,16,data
    """

    assert csv_string == String.trim(expected_string, "\n")
  end

  test "print to screen", %{metrics_no_tags: metrics} do
    expected_string = """
    timestamp,name,type,value
    1,test,last_value,10
    2,test,last_value,13
    4,test,last_value,15
    8,test,last_value,16
    """

    assert capture_io(fn ->
             CSV.export_metrics(metrics, tags: [], metric_name: "test", iodevice: :stdio)
           end) == expected_string
  end

  @tag :tmp_dir
  test "save to file", %{metrics_no_tags: metrics, tmp_dir: tmp_dir} do
    tmp_csv = Path.join(tmp_dir, "test.csv")

    {:ok, file} = File.open(tmp_csv, [:write])
    :ok = CSV.export_metrics(metrics, tags: [], metric_name: "test", iodevice: file)

    expected_string = """
    timestamp,name,type,value
    1,test,last_value,10
    2,test,last_value,13
    4,test,last_value,15
    8,test,last_value,16
    """

    assert File.read!(tmp_csv) == expected_string

    File.close(file)
  end
end
