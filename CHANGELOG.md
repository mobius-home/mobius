<!-- markdownlint-disable-file MD024 -->

# Changelog

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Major version zero (0.y.z) is for initial development. Anything MAY change at
any time. The public API SHOULD NOT be considered stable.

## [Unreleased]

### Changed

* `Mobius.plot/3` is now `Mobius.Exports.plot/4`
* `Mobius.to_csv/3` is now `Mobius.Exports.csv/4`
* `Mobius.filter_metrics/3` is now `Mobius.Exports.metrics/4`
* `Mobius.name()` is now `Mobius.instance()`
* Mobius functions that need to know the name of the mobius instance now
  expect `:mobius_instance` and not `:name`
* `Mobius.metric_name()` is no longer a list of `atoms()` but is not the metric
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

This release brings in a bunch of new functionality and bug fixes. Along with
basic maintenance like dependency updates and documentation improvements
(@ewildgoose).

### Added

- Create, save, and extract tar files that contain metric data, see
  `Mobius.Bundles` and `Mobius.make_bundle/2` for more information.
- `Mobius.filter_metrics/3` to filter for desired metrics to enable the
  metrics to be consumed externally (@ewildgoose)
- `Mobius.save/1` to manually save the state of the metric data for Mobius
  (@ewildgoose)
- `:autosave_interval` option to Mobius to enable a saving data at the given
  interval (@ewildgoose)

### Fixes

- Unit conversion not working correctly (@ewildgoose)
- Error handling for when the `:persistence_path` is missing (@ewildgoose)
- Error handling when there is no data to plot (@ewildgoose)
- Crash when plotting an array of identical values (@ewildgoose)
- Correct off by one error when plotting (@ewildgoose)

## [v0.3.6] - 2022-01-25

### Added

- Support for `Telemetry.Metrics.Summary` metric type

## [v0.3.5] - 2021-12-2

### Fixes

- Fix crash when initializing metrics table when the ETS file cannot be read (@jfcloutier)

## [v0.3.4] - 2021-11-15

### Fixes

- Fix crash when a history file is unreadable during initialization (@mdwaud)

## [v0.3.3] - 2021-10-20

### Fixes

- Not able to pass a path for persistence that contains non-existing sub
  directories. Thank you [LostKobrakai](https://github.com/LostKobrakai).

## [v0.3.2] - 2021-09-22

### Added

- Support for `Telemetry.Metrics.Sum` type
- Support for filtering CSV records by type with `:type` option

## [v0.3.1] - 2021-09-08

### Added

- Plot over the last `x` seconds via the `:last` plot option
- Plot from an absolute time via the `:from` plot option
- Plot to an absolute time via the `:to` plot option
- Print or save metric time series via `Mobius.to_csv/3`
- Remove tracking a metric by dropping it from the metric list passed to Mobius

### Changed

- `Mobius.plot/3` will only show the last 3 minutes of data by default

## [v0.3.0] - 2021-8-19

### Changed

- Deleted `Mobius.Charts` module. The functions in this module are now located
  in the `Mobius` module.

### Removed

- Support for specifying resolutions.

## [v0.2.0] - 2021-8-03

### Added

- `Mobius.Charts` module
- Persistence of historical information on graceful shutdown
- Ability to specify time resolutions for plots

### Changed

- Move `Moblus.plot/0` and `Mobius.info/0` to `Mobius.Charts` module

## v0.1.0 - 2021-7-16

Initial release!

[v0.3.7]: https://github.com/mattludwigs/mobius/compare/v0.3.6...v0.3.7
[v0.3.6]: https://github.com/mattludwigs/mobius/compare/v0.3.5...v0.3.6
[v0.3.5]: https://github.com/mattludwigs/mobius/compare/v0.3.4...v0.3.5
[v0.3.4]: https://github.com/mattludwigs/mobius/compare/v0.3.3...v0.3.4
[v0.3.3]: https://github.com/mattludwigs/mobius/compare/v0.3.2...v0.3.3
[v0.3.2]: https://github.com/mattludwigs/mobius/compare/v0.3.1...v0.3.2
[v0.3.1]: https://github.com/mattludwigs/mobius/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/mattludwigs/mobius/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/mattludwigs/mobius/compare/v0.1.0...v0.2.0
