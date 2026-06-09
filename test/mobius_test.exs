defmodule MobiusTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @persistence_dir System.tmp_dir!() |> Path.join("mobius_test")
  @default_args [
    persistence_dir: @persistence_dir,
    metrics: []
  ]
  @default_instance_str "mobius"

  setup do
    File.rm_rf!(@persistence_dir)
    File.mkdir_p(@persistence_dir)
  end

  test "starts" do
    assert {:ok, _pid} = start_supervised({Mobius, @default_args})
  end

  test "does not crash with a corrupt history file" do
    persistence_path = Path.join(@persistence_dir, @default_instance_str)
    File.mkdir_p(persistence_path)
    File.write!(file(persistence_path), <<>>)

    assert capture_log(fn ->
             assert {:ok, _pid} = start_supervised({Mobius, @default_args})
           end) =~ "Unable to load data because of :unsupported_version"
  end

  @tag capture_log: true
  test "boots without persistence when the persistence dir cannot be created" do
    # A file sits where the directory tree should go: mkdir_p cannot succeed.
    bad_parent = Path.join(@persistence_dir, "not_a_dir")
    File.write!(bad_parent, "occupied")

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 start_supervised({Mobius, persistence_dir: bad_parent, metrics: []})

        # Memory-only operation: queries work, saving fails without crashing.
        assert [] = Mobius.Exports.metrics("vm.memory.total", :last_value, %{})
        assert {:error, _reason} = Mobius.save()
      end)

    assert log =~ "could not create persistence directory"
  end

  test "a deleted persistence dir is recreated on save" do
    persistence_path = Path.join(@persistence_dir, @default_instance_str)
    {:ok, _pid} = start_supervised({Mobius, @default_args})

    assert :ok = Mobius.save(@default_instance_str)
    File.rm_rf!(persistence_path)

    # Writability can come and go — every save attempt re-creates the
    # directory, so persistence recovers on its own.
    assert :ok = Mobius.save(@default_instance_str)
    assert File.exists?(Path.join(persistence_path, "history"))
  end

  test "boots when a metric's histogram options are invalid, keeping the summary" do
    metrics = [
      Telemetry.Metrics.summary("boot.bad.hist",
        measurement: :v,
        reporter_options: [histogram: [min_indexable_value: "tiny"]]
      ),
      Telemetry.Metrics.summary("boot.typo.hist",
        measurement: :v,
        reporter_options: [histogram: [relative_accurracy: 0.05]]
      )
    ]

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

        :telemetry.execute([:boot, :bad], %{v: 1.0}, %{})
        :telemetry.execute([:boot, :typo], %{v: 1.0}, %{})

        for name <- ["boot.bad.hist", "boot.typo.hist"] do
          entries = Mobius.MetricsTable.get_entries_by_metric_name(:mobius, name)

          assert Enum.any?(entries, fn {_, type, _, _} -> type == :summary end)
          refute Enum.any?(entries, fn {_, type, _, _} -> is_tuple(type) end)
        end
      end)

    assert log =~ "Disabling histogram for metric boot.bad.hist"
    assert log =~ "Disabling histogram for metric boot.typo.hist"
  end

  test "integer histogram options are accepted and cast to floats" do
    metrics = [
      Telemetry.Metrics.summary("boot.int.hist",
        measurement: :v,
        reporter_options: [histogram: [min_indexable_value: 1, max_indexable_value: 1_000_000]]
      )
    ]

    assert {:ok, _pid} = start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

    :telemetry.execute([:boot, :int], %{v: 5.0}, %{})

    entries = Mobius.MetricsTable.get_entries_by_metric_name(:mobius, "boot.int.hist")
    assert Enum.any?(entries, fn {_, type, _, _} -> match?({:hist, _, _}, type) end)
  end

  test "can save persistence data" do
    persistence_path = Path.join(@persistence_dir, @default_instance_str)
    {:ok, _pid} = start_supervised({Mobius, @default_args})

    assert :ok = Mobius.save(@default_instance_str)
    assert File.exists?(Path.join(persistence_path, "history"))
    assert File.exists?(Path.join(persistence_path, "metrics_table"))
  end

  test "can autosave persistence data" do
    persistence_path = Path.join(@persistence_dir, @default_instance_str)
    {:ok, _pid} = start_supervised({Mobius, @default_args ++ [autosave_interval: 1]})
    refute File.exists?(Path.join(persistence_path, "history"))

    # Sleep for a bit and check we autosaved in the meantime
    Process.sleep(1_100)
    assert File.exists?(Path.join(persistence_path, "history"))
    assert File.exists?(Path.join(persistence_path, "metrics_table"))
  end

  describe "remove_all_data/1" do
    test "clears in-memory metrics, history, the event log, and persisted files" do
      persistence_path = Path.join(@persistence_dir, @default_instance_str)
      instance = String.to_atom(@default_instance_str)

      metrics = [
        Telemetry.Metrics.counter("remove_all_data.test.count",
          event_name: [:remove_all_data, :test]
        )
      ]

      {:ok, _pid} = start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

      # Record a metric and an event.
      :telemetry.execute([:remove_all_data, :test], %{count: 1}, %{})

      Mobius.EventsServer.insert(
        instance,
        Mobius.Event.new("test", "remove_all_data.event", %{a: 1}, %{}, timestamp: 1)
      )

      # In-memory metrics table now has an entry.
      assert Mobius.MetricsTable.get_entries(instance) != []

      # Give the scraper a tick to capture a snapshot into the RRD.
      Process.sleep(1_100)
      refute Enum.empty?(Mobius.Scraper.all(instance))

      # The event landed in the event log.
      assert Mobius.EventLog.list(instance: instance) != []

      # Persist everything to disk.
      assert :ok = Mobius.save(instance)
      assert File.exists?(Path.join(persistence_path, "history"))
      assert File.exists?(Path.join(persistence_path, "metrics_table"))
      assert File.exists?(Path.join(persistence_path, "event_log"))

      # Removing all data wipes it all out.
      assert :ok = Mobius.remove_all_data(instance)

      assert Mobius.MetricsTable.get_entries(instance) == []
      assert Mobius.Scraper.all(instance) == []
      assert Mobius.EventLog.list(instance: instance) == []

      refute File.exists?(Path.join(persistence_path, "history"))
      refute File.exists?(Path.join(persistence_path, "metrics_table"))
      refute File.exists?(Path.join(persistence_path, "event_log"))
    end

    test "keeps tracking configured metrics after removing all data" do
      instance = String.to_atom(@default_instance_str)

      metrics = [
        Telemetry.Metrics.counter("remove_all_data.again.count",
          event_name: [:remove_all_data, :again]
        )
      ]

      {:ok, _pid} = start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

      :telemetry.execute([:remove_all_data, :again], %{count: 1}, %{})
      assert Mobius.MetricsTable.get_entries(instance) != []

      assert :ok = Mobius.remove_all_data(instance)
      assert Mobius.MetricsTable.get_entries(instance) == []

      # The metric is still registered, so new measurements are recorded.
      :telemetry.execute([:remove_all_data, :again], %{count: 1}, %{})
      assert Mobius.MetricsTable.get_entries(instance) != []
    end

    test "a later save does not resurrect cleared data" do
      instance = String.to_atom(@default_instance_str)

      metrics = [
        Telemetry.Metrics.counter("remove_all_data.save.count",
          event_name: [:remove_all_data, :save]
        )
      ]

      {:ok, _pid} = start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

      :telemetry.execute([:remove_all_data, :save], %{count: 1}, %{})
      Process.sleep(1_100)

      assert :ok = Mobius.remove_all_data(instance)
      assert :ok = Mobius.save(instance)

      # The metrics table file may be written again, but it must hold no
      # recorded metrics, and the history must stay empty.
      assert Mobius.MetricsTable.get_entries(instance) == []
      assert Mobius.Scraper.all(instance) == []

      stop_supervised!(Mobius)

      {:ok, _pid} = start_supervised({Mobius, Keyword.put(@default_args, :metrics, metrics)})

      assert Mobius.MetricsTable.get_entries(instance) == []
      assert Mobius.Scraper.all(instance) == []
    end
  end

  defp file(persistence_dir) do
    Path.join(persistence_dir, "history")
  end
end
