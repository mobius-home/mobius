<!-- markdownlint-disable-file MD024 -->

# Changelog

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Major version zero (0.y.z) is for initial development. Anything MAY change at
any time. The public API SHOULD NOT be considered stable.

## Unreleased

### Added

* `Mobius.remove_all_data/0` and `Mobius.remove_all_data/1` to clear
  everything out and return Mobius to a clean state without a restart: the
  in-memory metrics table, the accumulated history (RRD), the event log,
  and the persisted files on disk (`history`, `metrics_table`, and
  `event_log`). Configured metrics and events keep being tracked, so
  collection resumes immediately. Useful when repurposing a device whose
  historical data is no longer meaningful, or while debugging and
  developing.
* DDSketch-backed histograms on `summary`-type metrics. Opt in per
  metric via `reporter_options: [histogram: [...]]` to get percentiles
  (P50/P95/P99), SLO-style "% under threshold" counts, and
  distribution-shape data alongside the existing summary aggregate.
  Query via `Mobius.Data.histogram/3`, `quantile/4`, `quantiles/4`,
  `count_below/4`, and `count_above/4`. See the Histogram
  configurations guide for worked examples.
* `Mobius.Data`: the programmatic query API. Returns plain
  `:ok`/`:error` tuples built for unattended callers (alerting rules,
  reports, SLO checks) — when the Mobius instance is down or busy the
  result is `{:error, :unavailable}` instead of a caller crash.
* `Mobius.DDSketch`: sparse mergeable quantile sketch backing the
  histogram feature. Configurable α (default 0.1, ±10%), value range,
  and overflow behaviour (`:clamp` saturates to the top bin, `:drop`
  silently skips).
* `Mobius.Scraper.all_histograms/2` for windowed access to the
  per-snapshot histogram data.

### Changed

* RRD format v3 snapshots now carry a `{records, histograms}` tuple,
  with the histogram bin data kept in its own map. The v2 -> v3
  migration wraps existing records in the new shape with an empty
  histogram map, so persisted v2 files keep loading.
* Mobius no longer raises at boot. Invalid histogram options disable
  the histogram for that metric (the summary keeps working) with one
  logged warning, and an unusable persistence directory degrades to
  memory-only operation — every save attempt retries the write, so
  persistence recovers when the filesystem allows.
* Every declared tag is now recorded on each metric series, as `nil`
  when the event metadata lacks it, so a series' identity no longer
  depends on which keys a particular event happened to carry.

### Removed

* Breaking change: `:min` and `:max` from summary metric output. These
  values were never reset for the lifetime of the process, so a single
  outlier would taint every later query.
  They were more confusing than helpful and are removed.
  The values are no longer returned from `Mobius.Exports.metrics/4` for the
  `summary` type.

## [v0.7.0] - 2026-05-21

### Changed

* Raised the minimum Elixir version to 1.15.
* Replaced the `uuid` dependency with `elixir_uuid`. The `uuid` hex package was
  rebranded as `elixir_uuid` starting with v1.2.0, and keeping the old name
  caused `mix release` to fail with duplicated `Elixir.UUID` modules in
  projects that also depend on `elixir_uuid`.
* `circular_buffer` requirement relaxed to `~> 0.4 or ~> 1.0`.

## [v0.6.1] - 2024-04-02

### Changed

* Allow `:telemetry_metrics` v1.0.0 and later now that it's been released
* Fix `Logger.warn` deprecations
* Fix binary format validation issue due to map sort order change in Erlang 26.

## [v0.6.0] - 2022-09-09

The breaking change in Mobius is the removal of remote reporting and the
functionality built around that such as configuring a remote reporter to send
a metric report at some interval.

If this functionality is something you still want, you can provide a GenServer
that executes your reporting code at some interval. This will allow the maximum
flexibility to how you want your software to report metrics.

### Changed

* Remove `Mobius.RemoteReporter`
* Remove `:remote_reporter` configuration from `Mobius.arg()`
* Remove `:remote_reporter_interval` configuration from `Mobius.arg()`
* Remove `Mobius.RemoteReporters.LoggerReporter`

### Added

* `Mobius.Event`
* `Mobius.EventLog`
* `Mobius.Clock`
* `Mobius.get_latest_metrics/1`
* `Mobius.get_latest_events/1`
* `:events` option to `Mobius.arg()`
* `:event_log_size` option to `Mobius.arg()`
* `:clock` option to `Mobius.arg()`
* `:session` option to `Mobius.arg()`
* `Mobius.session()`

## [v0.5.1] - 2022-06-01

### Added

- Added the ability for a remote reporter to response with
  `{:error, reason, new_state}`.

## [v0.5.0] - 2022-05-31

Breaking changes for three functions in the `Mobius.Exports` module:

1. `Mobius.Exports.series/4`
1. `Mobius.Exports.metrics/4`
1. `Mobius.Exports.plot/4`

If you are not directly calling these functions in your code you're safe to upgrade.

The first two used to return either `{:ok, results}` or `{:error, reason}` but
now they will only return their result. For `Mobius.Exports.series/4` the return
value is now `[integer()]` and for `Mobius.Exports.metrics/4` the return type is
now `[Mobius.metric()]`. `Mobius.Exports.plot/4` still returns `:ok` on success,
but can now return `{:error, UnsupportedMetricError.t()}`.

### Changed

* `Mobius.Exports.series/4` return type was
  `{:ok, [integer()]} | {:error, UnsupportedMetricError.t()}` and now is
  `[integer()]`.
* `Mobius.Exports.metrics/4` return type was
  `{:ok, [Mobius.metric()]} | {:error, UnsupportedMetricError.t()}` and now is
  `[Mobius.metric()]`
* `Mobius.Exports.plot/4` was just `:ok` but now is
  `:ok | {:error, UnsupportedMetricError.t()}`

### Added

* `Mobius.RemoteReporter` behaviour to allow for reporting metrics to a remote
  server.
* Add `:remote_reporter` and `:remote_report_interval` options to the
  `Mobius.arg()` type.
* Support for specifying which summary metric you want to export. (@ewildgoose)
* Support for summary metrics types in some exports. (@ewildgoose)
* Add standard deviation calculation to the summary metric type. (@ewildgoose)
* New `Mobius.Exports.export_metric_type()` that allows for specifying the
  summary metric type.

### Misc

* Update `ex_doc` to `v.0.28.4`
* Update `telemetry` to `v1.1.0`
* Fix up typos (@kianmeng)

## [v0.4.0] - 2022-03-25

### Changed

* `Mobius.plot/3` is now `Mobius.Exports.plot/4`
* `Mobius.to_csv/3` is now `Mobius.Exports.csv/4`
* `Mobius.filter_metrics/3` is now `Mobius.Exports.metrics/4`
* `Mobius.name()` is now `Mobius.instance()`
* Mobius functions that need to know the name of the mobius instance now
  expect `:mobius_instance` and not `:name`
* `Mobius.metric_name()` is no longer a list of `atoms()` but is now the metric
  name as a string
* `Mobius.RRD` internal metric format
* `Mobius.RRD.insert/3` typespec now expects `[Mobius.metric()]` as the last
  parameter

### Removed

* `Mobius.filter_opt()` type
* `Mobius.csv_opt()` type
* `Mobius.plot_opt()` type
* `Mobius.query_opts/1` function
* `Mobius.to_csv/3` function
* `Mobius.plot/3` function
* `Mobius.filter_metrics/3` function
* `Mobius.make_bundle/2` function (use `Mobius.mbf/1` instead)
* `Mobius.Bundle` module
* `Mobius.record()` type

### Added

* `Mobius.Exports` module for APIs concerning retrieving historical data in
  various formats
* `Mobius.Exports.csv/4` generates a CSV either as a string, to the console, or
  to a file
* `Mobius.Exports.series/4` generates a series for historical data
* `Mobius.Exports.metrics/4` retrieves the raw historical metric data
* `Mobius.Exports.plot/4` generates a line plot to the console
* `Mobius.Exports.mbf/1` generates a binary that contains all current metrics
* `Mobius.Exports.parse_mbf/1` parses a binary that is in the Mobius Binary Format
* `Mobius.Exports.UnsupportedMetricError`
* `Mobius.Exports.MBFParseError`
* `Mobius.FileError`
* `:name` field to `Mobius.metric()` type

## [v0.3.7] - 2022-03-16

This release brings in a bunch of new features and bug fixes. Along with
basic maintenance like dependency updates and documentation improvements
(@ewildgoose).

### Added

* Create, save, and extract tar files that contain metric data, see
  `Mobius.Bundles` and `Mobius.make_bundle/2` for more information.
* `Mobius.filter_metrics/3` to filter for desired metrics to enable the
  metrics to be consumed externally (@ewildgoose)
* `Mobius.save/1` to manually save the state of the metric data for Mobius
  (@ewildgoose)
* `:autosave_interval` option to Mobius to enable a saving data at the given
  interval (@ewildgoose)

### Fixes

* Unit conversion not working correctly (@ewildgoose)
* Error handling for when the `:persistence_path` is missing (@ewildgoose)
* Error handling when there is no data to plot (@ewildgoose)
* Crash when plotting an array of identical values (@ewildgoose)
* Correct off by one error when plotting (@ewildgoose)

## [v0.3.6] - 2022-01-25

### Added

* Support for `Telemetry.Metrics.Summary` metric type

## [v0.3.5] - 2021-12-2

### Fixes

* Fix crash when initializing metrics table when the ETS file cannot be read (@jfcloutier)

## [v0.3.4] - 2021-11-15

### Fixes

* Fix crash when a history file is unreadable during initialization (@mdwaud)

## [v0.3.3] - 2021-10-20

### Fixes

* Not able to pass a path for persistence that contains non-existing sub
  directories. Thank you [LostKobrakai](https://github.com/LostKobrakai).

## [v0.3.2] - 2021-09-22

### Added

* Support for `Telemetry.Metrics.Sum` type
* Support for filtering CSV records by type with `:type` option

## [v0.3.1] - 2021-09-08

### Added

* Plot over the last `x` seconds via the `:last` plot option
* Plot from an absolute time via the `:from` plot option
* Plot to an absolute time via the `:to` plot option
* Print or save metric time series via `Mobius.to_csv/3`
* Remove tracking a metric by dropping it from the metric list passed to Mobius

### Changed

* `Mobius.plot/3` will only show the last 3 minutes of data by default

## [v0.3.0] - 2021-8-19

### Changed

* Deleted `Mobius.Charts` module. The functions in this module are now located
  in the `Mobius` module.

### Removed

* Support for specifying resolutions.

## [v0.2.0] - 2021-8-03

### Added

* `Mobius.Charts` module
* Persistence of historical information on graceful shutdown
* Ability to specify time resolutions for plots

### Changed

* Move `Moblus.plot/0` and `Mobius.info/0` to `Mobius.Charts` module

## v0.1.0 - 2021-7-16

Initial release!

[v0.7.0]: https://github.com/mattludwigs/mobius/compare/v0.6.1...v0.7.0
[v0.6.1]: https://github.com/mattludwigs/mobius/compare/v0.6.0...v0.6.1
[v0.6.0]: https://github.com/mattludwigs/mobius/compare/v0.5.1...v0.6.0
[v0.5.1]: https://github.com/mattludwigs/mobius/compare/v0.5.0...v0.5.1
[v0.5.0]: https://github.com/mattludwigs/mobius/compare/v0.4.0...v0.5.0
[v0.4.0]: https://github.com/mattludwigs/mobius/compare/v0.3.7...v0.4.0
[v0.3.7]: https://github.com/mattludwigs/mobius/compare/v0.3.6...v0.3.7
[v0.3.6]: https://github.com/mattludwigs/mobius/compare/v0.3.5...v0.3.6
[v0.3.5]: https://github.com/mattludwigs/mobius/compare/v0.3.4...v0.3.5
[v0.3.4]: https://github.com/mattludwigs/mobius/compare/v0.3.3...v0.3.4
[v0.3.3]: https://github.com/mattludwigs/mobius/compare/v0.3.2...v0.3.3
[v0.3.2]: https://github.com/mattludwigs/mobius/compare/v0.3.1...v0.3.2
[v0.3.1]: https://github.com/mattludwigs/mobius/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/mattludwigs/mobius/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/mattludwigs/mobius/compare/v0.1.0...v0.2.0
