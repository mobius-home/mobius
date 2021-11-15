<!-- markdownlint-disable-file MD024 -->

# Changelog

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[v0.3.3]: https://github.com/mattludwigs/mobius/compare/v0.3.3...v0.3.4
[v0.3.3]: https://github.com/mattludwigs/mobius/compare/v0.3.2...v0.3.3
[v0.3.2]: https://github.com/mattludwigs/mobius/compare/v0.3.1...v0.3.2
[v0.3.1]: https://github.com/mattludwigs/mobius/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/mattludwigs/mobius/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/mattludwigs/mobius/compare/v0.1.0...v0.2.0
