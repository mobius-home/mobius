defmodule Mobius.TelemetryTest do
  use ExUnit.Case, async: true

  # Telemetry convention: measurements carry numeric values, while contextual
  # identifiers (metric type, failure reason, instance) belong in metadata.

  describe "[:mobius, :export, :metrics, :stop]" do
    @tag :tmp_dir
    test "carries the metric type in the stop metadata", %{tmp_dir: tmp_dir} do
      instance = :telemetry_export_stop
      handler_id = {__MODULE__, :export_stop}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mobius, :export, :metrics, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:export_stop, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} =
        start_supervised(
          {Mobius, mobius_instance: instance, persistence_dir: tmp_dir, metrics: []}
        )

      _rows =
        Mobius.Exports.metrics("vm.memory.total", :last_value, %{}, mobius_instance: instance)

      assert_receive {:export_stop, %{duration: _}, %{mobius_instance: ^instance} = metadata}
      assert metadata[:type] == :last_value
    end
  end

  describe "[:mobius, :save, :exception]" do
    @tag :tmp_dir
    @tag capture_log: true
    test "puts the failure reason in the metadata", %{tmp_dir: tmp_dir} do
      instance = :telemetry_save_exception
      handler_id = {__MODULE__, :save_exception}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mobius, :save, :exception],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:save_exception, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A file occupies the persistence path, so every save attempt fails.
      bad_parent = Path.join(tmp_dir, "not_a_dir")
      File.write!(bad_parent, "occupied")

      {:ok, _} =
        start_supervised(
          {Mobius, mobius_instance: instance, persistence_dir: bad_parent, metrics: []}
        )

      assert {:error, _reason} = Mobius.save(instance)

      assert_receive {:save_exception, %{duration: _}, %{instance: ^instance} = metadata}
      assert metadata[:reason]
    end
  end
end
