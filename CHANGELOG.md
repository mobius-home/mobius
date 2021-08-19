# Changelog

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[v0.3.0]: https://github.com/mattludwigs/mobius/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/mattludwigs/mobius/compare/v0.1.0...v0.2.0