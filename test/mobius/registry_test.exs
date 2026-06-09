defmodule Mobius.RegistryTest do
  use ExUnit.Case, async: false

  alias Mobius.{MetricsTable, Registry}
  alias Telemetry.Metrics

  test "removes restored entries for metrics that are no longer configured" do
    table = :registry_stale_prune_test
    MetricsTable.init(mobius_instance: table, persistence_dir: "/does/not/matter/here")

    # Simulate entries restored from a persisted table: one for a metric that
    # is still configured, one for a metric that no longer is, and a histogram
    # bin row which the registry must never touch.
    :ok = MetricsTable.put(table, [:vm, :memory, :total], :last_value, 100)
    :ok = MetricsTable.put(table, [:old, :metric], :counter, 1)
    :ok = MetricsTable.inc_histogram_bin(table, [:old, :metric], {:hist, :pos, 3})

    metrics = [Metrics.last_value("vm.memory.total")]

    start_supervised!({Registry, mobius_instance: table, metrics: metrics})

    # Pruning runs in a handle_continue; a call ensures it has completed.
    assert ^metrics = Registry.metrics(table)

    entries = MetricsTable.get_entries(table)

    # The entry for the still-configured metric is kept.
    assert {"vm.memory.total", :last_value, 100, %{}} in entries

    # The stale entry is removed.
    refute {"old.metric", :counter, 1, %{}} in entries

    # Histogram bin rows are not pruned by the registry.
    assert {"old.metric", {:hist, :pos, 3}, 1, %{}} in entries
  end

  test "keeps restored entries for configured metrics with tags in declaration order" do
    table = :registry_tagged_prune_test
    MetricsTable.init(mobius_instance: table, persistence_dir: "/does/not/matter/here")

    :ok =
      MetricsTable.put(table, [:tagged, :metric, :count], :counter, 1, %{
        zone: "a",
        host: "h"
      })

    # Tags declared in non-sorted order: comparing them against the sorted
    # keys of the entry metadata must not prune the entry.
    metrics = [Metrics.counter("tagged.metric.count", tags: [:zone, :host])]

    start_supervised!({Registry, mobius_instance: table, metrics: metrics})

    assert ^metrics = Registry.metrics(table)

    assert {"tagged.metric.count", :counter, 1, %{zone: "a", host: "h"}} in MetricsTable.get_entries(
             table
           )
  end
end
