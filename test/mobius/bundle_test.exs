defmodule Mobius.BundleTest do
  use ExUnit.Case, async: true

  alias Mobius.Bundle

  test "create a bundle" do
    records = [{123_123_123, [{[:fake, :event, :name, :last_value, 100, %{}]}]}]
    bundle = Bundle.new("target_name", records)

    assert bundle.data == records
    assert bundle.meta.version == 1
    assert bundle.meta.target == "target_name"
    assert bundle.meta.number_of_records == 1
  end

  @tag :tmp_dir
  test "save bundle and extract no compression", %{tmp_dir: tmp_dir} do
    records = [{123_123_123, [{[:fake, :event, :name, :last_value, 100, %{}]}]}]
    bundle = Bundle.new("target_name", records)

    assert {:ok, saved_path} = Bundle.save(bundle, out_dir: tmp_dir, prefix: "test_save_extract")
    assert Path.basename(saved_path) == "test_save_extract_mobius_bundle.tar"

    assert {:ok, bundle} == Bundle.extract(saved_path, extract_dir: tmp_dir)
    assert File.ls!(tmp_dir) == [Path.basename(saved_path)]
  end

  @tag :tmp_dir
  test "save bundle and extract with compression", %{tmp_dir: tmp_dir} do
    records = [{123_123_123, [{[:fake, :event, :name, :last_value, 100, %{}]}]}]
    bundle = Bundle.new("target_name", records)

    assert {:ok, saved_path} =
             Bundle.save(bundle, [
               {:out_dir, tmp_dir},
               {:prefix, "test_save_extract"},
               :compressed
             ])

    assert Path.basename(saved_path) == "test_save_extract_mobius_bundle.tar.gz"

    assert {:ok, bundle} == Bundle.extract(saved_path, extract_dir: tmp_dir)
    assert File.ls!(tmp_dir) == [Path.basename(saved_path)]
  end

  @tag :tmp_dir
  test "extract time conversation NaiveDateTime", %{tmp_dir: tmp_dir} do
    system_time = System.system_time(:second)
    records = [{system_time, [{[:fake, :event, :name, :last_value, 100, %{}]}]}]
    bundle = Bundle.new("target_name", records)

    {:ok, saved_path} =
      Bundle.save(bundle, out_dir: tmp_dir, prefix: "test_save_extract_native_date_time")

    {:ok, extracted_bundle} =
      Bundle.extract(saved_path, extract_dir: tmp_dir, time_as: NaiveDateTime)

    [{converted_datetime, _} | _] = extracted_bundle.data

    assert converted_datetime == DateTime.from_unix!(system_time) |> DateTime.to_naive()

    assert File.ls!(tmp_dir) == [Path.basename(saved_path)]
  end

  @tag :tmp_dir
  test "extract time conversation DateTime", %{tmp_dir: tmp_dir} do
    system_time = System.system_time(:second)
    records = [{system_time, [{[:fake, :event, :name, :last_value, 100, %{}]}]}]
    bundle = Bundle.new("target_name", records)

    {:ok, saved_path} =
      Bundle.save(bundle, out_dir: tmp_dir, prefix: "test_save_extract_native_date_time")

    {:ok, extracted_bundle} = Bundle.extract(saved_path, extract_dir: tmp_dir, time_as: DateTime)

    [{converted_datetime, _} | _] = extracted_bundle.data

    assert converted_datetime == DateTime.from_unix!(system_time)

    assert File.ls!(tmp_dir) == [Path.basename(saved_path)]
  end

  @tag :tmp_dir
  test "error extracting invalid tar file", %{tmp_dir: tmp_dir} do
    assert {:error, %Bundle.ExtractError{} = error} =
             Bundle.extract("mix.exs", extract_dir: tmp_dir)

    assert Exception.message(error) ==
             "Error extracting the bundle during Extracting into #{tmp_dir}/mix.exs because :invalid_tar_checksum"
  end

  @tag :tmp_dir
  test "error extracting missing file", %{tmp_dir: tmp_dir} do
    assert {:error, %Bundle.ExtractError{} = error} =
             Bundle.extract("does_not_exist", extract_dir: tmp_dir)

    assert Exception.message(error) ==
             "Error extracting the bundle during Extracting file: does_not_exist because :enoent"
  end
end
