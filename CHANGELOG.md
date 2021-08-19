# Changelog

## [v0.3.0] 2021-8-19

### Changed
- Deleted `Mobius.Charts` module. The functions in this module are now located
  in the `Mobius` module.

### Removed
- Support for specifying resolutions.


## v0.2.0 (2021-8-03)

Provides time based resolution and will backup historical data on graceful
shutdown.

Breaking changes:

1. `Mobius.plot/0` -> `Mobius.Charts.plot/3`
1. `Mobius.info/0` -> `Mobius.Charts.info/0` 

## v0.1.0 (2021-7-16)

Initial release!